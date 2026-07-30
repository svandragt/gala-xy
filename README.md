# gala-xy

A small plugin for [Gala](https://github.com/elementary/gala), the window
manager behind elementaryOS's Pantheon desktop.

Right now all it does is draw a highlighted border around the focused window,
so you can always tell which window has focus at a glance. It does not move,
resize, or reorder anything.

It started as a [PaperWM](https://github.com/paperwm/PaperWM)-style horizontal
tiling plugin. That layer caused more trouble than it was worth and has been
removed for now while the layout model gets rethought — see the git history if
you want it back.

## What it does

- The focused window gets a highlighted border, coloured to match your
  System Settings → Appearance accent colour, updating live if you change it.
- Panels, docks, and similar chrome don't get a border (see below).

## Excluding windows

Wingpanel and Plank are excluded by default, matched by a substring in their
window title; anything else can be added the same way, or by GTK application
ID if the app has more than one window and only some should be excluded —
either via **System Settings → Tiling**, or with `gsettings`:

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
