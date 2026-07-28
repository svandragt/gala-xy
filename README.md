# gala-xy

I wanted [PaperWM](https://github.com/paperwm/PaperWM)-style tiling on
elementaryOS, so this is a horizontal tiling plugin for
[Gala](https://github.com/elementary/gala), the window manager behind
Pantheon.

Windows on a workspace sit in a single horizontal row, each one full height.
You reorder them, switch between them with the keyboard, and the focused
window gets a highlighted border so you can always tell where you are.

It does **not** touch how workspaces work – Pantheon's existing workspace
switching (`Super+Left/Right` by default) is untouched. It's only the layout
*within* a workspace that changes.

## What it does

- Every normal window on a workspace tiles edge-to-edge in a row, full
  height, keeping whatever width it currently has – windows never overlap,
  except a maximised window, which is left alone to fill the monitor as
  normal and snaps back into its row slot on unmaximise.
- Each monitor gets its own independent row per workspace.
- A newly opened window lands right after whichever window you last had
  focused in that row, not always at the end.
- The focused window gets a highlighted border, coloured to match your
  System Settings → Appearance accent colour, so you can always tell which
  window has focus at a glance – and it updates live if you change the
  accent colour.
- Windows dragged onto a different monitor move into that monitor's row.
- Resizing the edge a window shares with its row-neighbour moves that shared
  boundary like elementary's own snapped-window divider – the neighbour
  resizes in tandem instead of leaving a gap or an overlap. That one I added
  after noticing it's how elementary already handles two windows snapped
  left/right, and it felt wrong not to have it for tiled windows too.
- A window can be floated out of the row entirely – it keeps whatever
  position and size it has and is left alone by tiling until you unfloat it
  again (repeat the same drag/shortcut, cycle its width, or maximise it).

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Super+[` / `Super+]` | Move keyboard focus to the window left/right in the row |
| `Super+Shift+[` / `Super+Shift+]` | Move the focused window itself left/right in the row |
| `Super+R` | Cycle the focused window's width between 33%, 50%, and 67% of the monitor, shrinking or growing its row-neighbour to compensate |
| `Super+\` | Toggle floating for the focused window |

Every `Super`+arrow-key combination is already claimed by Pantheon/GNOME
defaults (workspace switching, move-to-monitor, move-to-workspace, tiling),
so these use the bracket keys instead — check `gsettings list-recursively`
against `org.gnome.desktop.wm.keybindings`, `org.gnome.mutter.keybindings`,
and `io.elementary.desktop.wm.keybindings` before picking something else.

Rebind these in a terminal with `gsettings`, e.g.:

```
gsettings set org.pantheon.desktop.gala.plugins.xy focus-left "['<Super>comma']"
```

...or through **System Settings → Tiling** — a `switchboard-plug` package
(`make install` installs it alongside the plugin itself). Shortcuts get a
proper capture UI there: click a row, press the combo, done, with support
for more than one shortcut per action. The exclusion lists below are plain
comma-separated text fields instead, since they're free-form strings rather
than key combos.

## Excluding windows from tiling

Panels, docks, and similar chrome are excluded from the row rather than being tiled at
full monitor width. Wingpanel and Plank are excluded by default, matched by a substring
in their window title; anything else can be added the same way, or by GTK application ID
if the app has more than one window and only some of them should be excluded — either via
System Settings → Tiling, or with `gsettings`:

```
gsettings set org.pantheon.desktop.gala.plugins.xy excluded-title-keywords "['wingpanel', 'plank', 'some-substring']"
gsettings set org.pantheon.desktop.gala.plugins.xy excluded-app-ids "['com.vandragt.sidewing', 'some.other.app']"
```

Small popups and confirmation dialogs (auth prompts, save-changes dialogs) are also left
alone rather than tiled, based on a minimum width/height in pixels (default 150,
`min-tileable-size`):

```
gsettings set org.pantheon.desktop.gala.plugins.xy min-tileable-size 200
```

## Mouse

Drag a window and drop it between two others in the row to reorder it there.

Drag the edge a window shares with its row-neighbour to resize both at once,
the shared boundary moving like a divider.

Drag a window to the bottom edge of its monitor to float it out of the row –
drag it there again to unfloat it.

## Installing

Requires `libgala-dev` and a Gala source checkout (for `libmutter-14.vapi`,
which Ubuntu's Mutter packages don't ship separately — point
`gala_vapi_dir` at yours if it's not at the default path in `meson_options.txt`).

```
make install
```

(equivalent to `meson setup build && ninja -C build && sudo ninja -C build install`)

Then log out and back in to pick it up. Don't use `gala --replace` or
`systemctl --user kill` to reload in place — both are known to trigger an
unrelated, pre-existing Mutter crash (`meta_x11_barriers_free` assertion on
teardown) that's confusing to debug around if you don't know it's coming.

## Uninstalling

```
make uninstall
```

Then log out and back in the same as above.

## Known limitations

- Built and tested against Gala 8.5.1 / Mutter 46 (elementaryOS 8-era). Other
  versions may need adjusting the `HAS_MUTTER*` defines in `meson.build`.
- Connecting or disconnecting a monitor while Gala is running isn't picked up
  live — restart Gala afterwards to get a row on the new monitor.
- No animation on retile yet; windows snap into place instantly.
- No horizontal scrolling/viewport: once a row is wider than the monitor,
  overflowing windows just stack on top of each other at the right edge
  instead of becoming pannable. I tried building a real scrolling viewport
  twice and reverted both times – Mutter has no clean way to actually hide
  a window that's scrolled out of view, and everything I tried around that
  either fought the window manager or felt worse than just living with the
  overflow.
- This is a young, unofficial plugin, not an elementary/Gala project. If Gala
  crashes after installing it, remove the `.so` from the plugins directory
  and reload Gala to get back to a stock session.
