# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`gala-xy`: a plugin for Gala (the window manager behind elementaryOS's Pantheon desktop),
built against the public `libgala-dev` plugin API — not a Gala fork.

It used to be a PaperWM-inspired horizontal tiling plugin. All of that (rows, `retile()`,
reorder/focus-neighbour/cycle-width keybindings, drag-to-rehome, divider resize, floating)
was removed wholesale — the tiling model needs rethinking. See git history before
`8d49fea` for the previous implementation and the reasoning behind its various hacks.

What's left: a focus ring around the focused window, plus Super+Left/Right to switch
focus between windows (most-recently-used order, not tiling), with an on-screen panel
listing that order while switching.

## Build / install / reload

```
make build      # meson setup + ninja
make install    # build + sudo ninja install (installs both .so's + gschema)
make uninstall  # remove both .so's and the schema, recompile schemas
make clean      # rm -rf build
make lint       # io.elementary.vala-lint src/*.vala switchboard-plug/*.vala
make format     # io.elementary.vala-lint -f ... (auto-fixes what it can)
```

`meson.build` produces two shared objects from one project: `libgala-xy.so` (the Gala
plugin itself, `src/*.vala`) and `libxy-settings.so` (a Switchboard settings plug,
`switchboard-plug/*.vala`, installed to Switchboard's `personal` category) — see "Settings"
below. Both need `make install` and a log out/in (or, for the Switchboard plug alone,
just restarting Switchboard) to pick up.

Requires `libgala-dev` and a Gala source checkout for `libmutter-14.vapi` (Ubuntu's
Mutter packages don't ship a standalone vapi). Point `gala_vapi_dir` in
`meson_options.txt` at your checkout if it isn't at the default path.

Linting/formatting uses `io.elementary.vala-lint` (elementary's own Vala linter), configured
via `vala-lint.json` at the repo root (currently the tool's defaults). It has no separate
formatter mode — `-f`/`make format` auto-fixes whatever the linter itself flags as
auto-fixable (spacing, brace style, etc.); it won't wrap long lines. Run `make lint` before
committing.

**Reloading after a change: log out and back in.** Do not use `systemctl --user kill` or
`gala --replace` to reload — both are known to trigger an unrelated, pre-existing Mutter
crash (`meta_x11_barriers_free` assertion on teardown), separate from anything in this
plugin, but confusing to debug around. `io.elementary.gala@x11.service` is a
dependency-only static unit; logging out lets it come back up cleanly on its own.

There is no automated test suite (the geometry test went with the tiling math it covered).
Verify changes by installing, reloading, and reading `journalctl _COMM=gala | grep xy`.

## Architecture

Four Vala files compiled into one `libgala-xy.so`, registered via `register_plugin()`
at the bottom of `src/Main.vala` (`Gala.PluginFunction.ADDITION`, `IMMEDIATE` load priority).

- **`Main.vala`** — nothing but the plugin shell: construct `FocusRing` and
  `WindowSwitcher` on `initialize()`, destroy them on `destroy()`.
- **`WindowSwitcher.vala`** — registers the `switch-left`/`switch-right` keybindings
  (defaults Super+Left/Right) via `display.add_keybinding()` against the plugin's own
  gschema, and steps focus through the active workspace's windows in most-recently-used
  order, wrapping at the ends. `activate()` promotes its window to the front of Mutter's
  tab list, so reading `get_tab_list(NORMAL)` live each press would just ping-pong between
  the two most-recent windows; instead the MRU order is snapshotted (as
  `get_stable_sequence()` ids, which survive window close) and held frozen while stepping,
  with the position re-derived from the actually-focused window each press. A
  `do_focus_window` handler drops the snapshot on any focus change that wasn't one of its
  own switches (tracked via an `expecting` sequence id), so real focus moves reseed it.
  Skips chrome via the shared `FocusRing.is_chrome_window()` (why it's `internal`). Hands
  the frozen order and the new position to `SwitcherPanel` on each switch, and hides it
  again whenever a real focus change drops that order.
- **`SwitcherPanel.vala`** — the transient OSD `WindowSwitcher` shows on each switch: a
  centred vertical list of the frozen MRU order's window titles with the newly-focused
  one highlighted in the Granite accent color, so the rows between the highlight and a
  given window are the number of presses away it is. Drawn entirely in one Cairo pass on
  a `Gala.CanvasActor` with PangoCairo (same reason as `FocusRing`: it's the drawing path
  already proven against the Mutter 46 vapi), sized from the widest measured title, and
  faded out by a `GLib.Timeout` that is re-armed on every press (`switcher-panel-timeout`,
  default 1000 ms; `switcher-panel` turns it off entirely). Unlike the focus ring it stays
  in `ui_group` and is raised to the top there, since it's meant to cover everything.
- **`FocusRing.vala`** — a `Gala.CanvasActor` subclass stroking a rounded-rect border (via
  `Gala.Drawing.Utilities.cairo_rounded_rectangle`, not `Clutter.Canvas`, which the vapi
  excludes as of Mutter 46) tracking the focused window's frame rect via `do_focus_window` +
  `position_changed`/`size_changed`. Drawn *inset* within the window's own frame rect rather
  than offset outside it, so it can't get clipped off the edge of the stage when a window is
  full-width/full-height on its monitor. `is_chrome_window()` reads the
  `excluded-title-keywords`/`excluded-app-ids` gschema keys so panels/docks don't get a ring
  (Sidewing is matched by GTK application ID rather than title, since only its main bar's
  title actually contains "sidewing").

Recurring Vala/vapi gotcha: several Mutter signal vapis declare `Meta.Window` parameters
non-nullable when Mutter actually passes null (e.g. focus cleared) — always use a named
handler with an explicit `Meta.Window?` parameter, never an inline lambda, or Vala's
auto-inserted null assertion crashes Gala.

## Settings

`switchboard-plug/` is a separate build target (`libxy-settings.so`) from the Gala
plugin — a Switchboard plug, not part of `libgala-xy.so`, installed into Switchboard's
`personal` category. It has no logic of its own: it's a GTK4 view over the same
`org.pantheon.desktop.gala.plugins.xy` gschema the plugin itself reads (two exclusion
lists on the Exclusions page, the two switch keybindings on the Shortcuts page, the
switcher panel's enable/timeout on the Panel page), using
`GLib.Settings.bind_with_mapping()` to show/edit each `as` (string array) key as a single
comma-separated `Gtk.Entry` (the two strv pages share a `StrvEntryPage` base for that
binding; every page shares `BasePage` for the description+grid layout, and the Panel
page's scalar `b`/`i` keys need only a plain `GLib.Settings.bind()`). The mapping delegates use
GSettings' plain-C-function-pointer form (`SettingsBindGetMappingShared`/
`...SetMappingShared`, `has_target = false` in the vapi) rather than closures, since that's
the only overload the vapi exposes — hence they're `static` methods taking an unused
`void* user_data`, not instance methods or lambdas.

The plug's entry point is a top-level `get_plug (GLib.Module module)` function (not a class
member) — this is Switchboard's actual loader contract: it `dlopen`s the `.so` and looks up
that exact symbol name, established empirically from `nm -D` on an installed system plug
(`io.elementary.settings.mouse-touchpad`) since the C header doesn't declare it. No
Switchboard shell binary is installed in this dev environment to click through by hand —
verified instead with a standalone C harness that `dlopen`s the built `.so`, calls
`get_plug`/`get_widget()` directly, and round-trips a value through the binding both ways
(gsettings write → entry text updates; typing in the entry → gsettings updates) against a
temporary `GSETTINGS_SCHEMA_DIR`, without touching the real installed schema.
