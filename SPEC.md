# gala-xy — product specification

This is the behavioural source of truth for gala-xy. It describes *what the
product does*, in product terms, with no reference to code. Changes to
behaviour should be made here first, then implemented.

gala-xy started as a PaperWM-style horizontal tiling plugin. That layer caused
too many problems in daily use and was removed pending a rethink of the layout
model; both it and the spec describing it are in the git history. What follows
is only what the product does today.

## 1. Purpose and scope

- gala-xy adds a focus indicator to elementaryOS (Pantheon), as a plugin to the
  existing window manager rather than a replacement for it.
- It does not move, resize, or reorder any window. Workspaces, layout, and
  window management behave exactly as stock Pantheon does.
- It is an unofficial, single-purpose plugin. If it fails, the user must be
  able to remove it and return to a stock session.

## 2. Focus indicator

- The focused window is outlined with a highlighted border, so the user can
  always tell where focus is.
- The border uses the system accent colour from System Settings → Appearance,
  and updates live when that changes.
- The border is drawn **inside** the window's own bounds, so it stays fully
  visible even for a window filling the whole monitor.
- It follows the focused window as it moves and resizes, and disappears when
  no window has focus.

## 3. Excluded windows

- System chrome gets no border. Wingpanel and Plank are excluded out of the
  box.
- The user can exclude any window by **window-title substring** or by
  **application ID**. App ID exclusion exists for apps where only *some* of
  their windows are chrome.
- Exclusion lists are read whenever a window takes focus, so a change applies
  without restarting anything.

## 4. Settings

- Both exclusion lists live in one system-wide settings store shared by the
  plugin and its settings UI, so changes from either side are picked up by the
  other.
- They appear in **System Settings → Tiling**, installed alongside the plugin,
  as free-form comma-separated text fields, and are equally settable from the
  command line.

## 5. Non-goals and known limitations

- No tiling, and no window movement of any kind — see the note at the top.
- The border's corner radius approximates the common Granite/GTK default; a
  window's real client-side radius isn't available to a plugin.
- Built and verified against the elementaryOS 8-era window manager; other
  versions may need adjustment.

## 6. Quality expectations

- The plugin must never take down the window manager. A failure should degrade
  to "the border stops appearing", not "the session is unusable".
- The border must never be left behind on a window that has lost focus or
  closed.
