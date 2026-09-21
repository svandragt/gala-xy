# gala-xy

A small plugin for [Gala](https://github.com/elementary/gala), the window
manager behind elementaryOS's Pantheon desktop.

It draws a highlighted border around the focused window so you can always tell
which window has focus at a glance, and it switches focus between windows with
Super+Left and Super+Right. It does not move, resize, or reorder anything.

## What it does

- The focused window gets a highlighted border, coloured to match your
  System Settings → Appearance accent colour, updating live if you change it.
- Super+Left and Super+Right move focus between the open windows on the current
  workspace, in most-recently-used order and wrapping at the ends — like
  Alt+Tab. Panels, docks, and excluded windows are skipped.
- Each press raises the window it lands on. A window you step past on the
  way drops back to the stacking position it had before you started
  switching, so walking several windows deep doesn't drag every one you
  passed to the front. If you tap the shortcut without holding the modifier,
  each press is its own run, so that window keeps its raise.
- While switching, an on-screen panel lists the windows in the current run,
  centred on whichever monitor you started on, with the one you've just
  landed on highlighted — the rows between the highlight and any other entry
  are how many presses away it is. It fades out once you let go of the
  modifier.
- Panels, docks, and similar chrome don't get a border (see below).
- The whole plugin can be switched off in place — see "Enabling and
  disabling" below.

## Shortcuts

The switch shortcuts default to Super+Left and Super+Right. Change them via
**System Settings → Window Behaviour → Shortcuts**, or with `gsettings`:

```
gsettings set org.pantheon.desktop.gala.plugins.xy switch-left "['<Super>Left']"
gsettings set org.pantheon.desktop.gala.plugins.xy switch-right "['<Super>Right']"
```

## Switcher panel

The panel shown while switching is on by default. Turn it off, or change how
long it stays up after you let go of the modifier, via
**System Settings → Window Behaviour → Panel**, or with `gsettings`:

```
gsettings set org.pantheon.desktop.gala.plugins.xy switcher-panel false
gsettings set org.pantheon.desktop.gala.plugins.xy switcher-panel-timeout 1500
```

`switcher-panel-timeout` is in milliseconds, from 200 to 10000.

## Enabling and disabling

Turning the plugin off removes the focus ring and the switcher panel and
releases Super+Left/Right back to Gala's own snap-tiling, without needing to
uninstall or log out — useful for telling whether a problem comes from this
plugin or from Gala/Mutter itself. `Ctrl+Alt+Super+X` toggles it and keeps
working even while the plugin is off. Change either via
**System Settings → Window Behaviour → General**, or with
`gsettings`:

```
gsettings set org.pantheon.desktop.gala.plugins.xy enabled false
gsettings set org.pantheon.desktop.gala.plugins.xy toggle-enabled "['<Control><Alt><Super>x']"
```

## Excluding windows

Wingpanel and Plank are excluded by default, matched by a substring in their
window title; anything else can be added the same way, or by GTK application
ID if the app has more than one window and only some should be excluded —
either via **System Settings → Window Behaviour → Exclusions**, or
with `gsettings`:

```
gsettings set org.pantheon.desktop.gala.plugins.xy excluded-title-keywords "['wingpanel', 'plank', 'some-substring']"
gsettings set org.pantheon.desktop.gala.plugins.xy excluded-app-ids "['com.vandragt.sidewing', 'some.other.app']"
```

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
- The border's corner radius is an approximation of the common Granite/GTK
  default — a window's real client-side radius isn't queryable from a plugin.
- This is a young, unofficial plugin, not an elementary/Gala project. If Gala
  crashes after installing it, remove the `.so` from the plugins directory
  and reload Gala to get back to a stock session.
