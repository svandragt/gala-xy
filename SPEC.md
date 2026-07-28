# gala-xy — product specification

This is the behavioural source of truth for gala-xy. It describes *what the
product does*, in product terms, with no reference to code. Changes to
behaviour should be made here first, then implemented.

## 1. Purpose and scope

- gala-xy gives elementaryOS (Pantheon) a PaperWM-style horizontal tiling
  layout, as a plugin to the existing window manager rather than a
  replacement for it.
- It changes **only the layout of windows within a workspace**. Workspace
  creation, switching, and the workspace overview behave exactly as stock
  Pantheon does.
- It is an unofficial, single-purpose plugin. If it fails, the user must be
  able to remove it and return to a stock session.

## 2. The core layout model

- Every workspace, on every monitor, has one **row**: a single horizontal
  line of windows.
- Windows in a row sit edge-to-edge, left to right, with no gaps and no
  overlap.
- Each window fills the full height of the monitor's work area (i.e. below
  the panel, above the dock).
- Each window keeps whatever **width** it currently has. The product never
  redistributes widths on its own; width is only ever changed by an explicit
  user action.
- Each monitor has its own independent row per workspace. Rows never share
  windows and never spill onto a neighbouring monitor.
- A window belongs to exactly one row for as long as it exists on that
  workspace and monitor. Ownership does not silently move.

## 3. Which windows are tiled

Tiled:

- Ordinary application windows that are visible and not minimised.

Not tiled (left exactly where they are):

- System chrome: panels and docks. Wingpanel and Plank are excluded out of
  the box.
- Any window the user has excluded by **window-title substring** or by
  **application ID**. App ID exclusion exists for apps where only *some* of
  their windows are chrome.
- Small transient windows — authentication prompts, save-changes dialogs and
  similar — identified by being below a minimum width or height (default
  150px, user-configurable).
- Maximised windows, which are left to fill the monitor as normal.
- Floating windows (section 6).

Rules:

- Exclusion lists take effect **immediately** on already-open windows, not
  only on newly opened ones.
- A window that only reveals what it is after it has opened (no title yet at
  the moment it appears) must still end up correctly excluded once its
  identity is known.
- Minimising removes a window from its row; restoring puts it back.
- Unmaximising returns a window to its slot in the row.

## 4. Ordering

- A newly opened window is inserted **immediately after the window that was
  last focused** in that row — not appended to the end. Opening a window next
  to what you were working on is the expected behaviour.
- Otherwise, order is stable: nothing reorders itself.

## 5. User actions

### Keyboard (all rebindable)

| Default | Action |
|---|---|
| `Super+[` / `Super+]` | Move focus to the window left / right in the row |
| `Super+Shift+[` / `Super+Shift+]` | Move the focused window itself left / right in the row |
| `Super+R` | Cycle the focused window's width through 33%, 50%, 67% of the monitor |
| `Super+\` | Float / unfloat the focused window |

- Focus movement **wraps**: stepping right from the last window in the row
  focuses the first, and stepping left from the first focuses the last. A row
  is a loop for focus purposes.
- Moving a window within the row does **not** wrap; it stops at either end.
- Width cycling shrinks or grows the row-neighbour to compensate, so the row
  stays gapless. It never reaches across the row: only a window's immediate
  neighbour absorbs the change, and it stops at the ends rather than wrapping.
  The neighbour to the right absorbs it by default; if there isn't a usable
  one — the window is last in the row, or its right neighbour is floating,
  maximised or minimised — the left neighbour absorbs it instead, so the last
  window in a row can still be cycled without overflowing the monitor.
- Width cycling reads the window's *current* width to decide the next step,
  so it behaves sensibly after a manual resize.
- Bracket keys are used because every `Super`+arrow combination is already
  taken by Pantheon/GNOME defaults.
- Keyboard actions always act on the window's actual row, so they still work
  on a window whose state is unusual (floating, recently moved).

### Mouse

- **Reorder**: drag a window and drop it between two others in the row.
- **Move between monitors**: drag a window to another monitor; it joins that
  monitor's row at the drop position.
- **Divider resize**: drag the edge a window shares with its row-neighbour.
  Both windows resize together and the shared boundary moves like a divider —
  matching how elementary already behaves for two windows snapped
  left/right. No gap, no overlap, and the far edges stay put.
- **Float**: drag a window to the bottom edge of its monitor. Drag it there
  again to unfloat.

### During any drag

- The window under the pointer is never fought by the layout. Tiling must not
  reposition or resize a window mid-drag, and must not snap it back after a
  resize.
- The layout settles once, after the drag has finished and the window
  manager's own churn has stopped — not on a fixed delay, and not
  repeatedly.

### One deliberate exception: newly opened windows

Some applications restore their own remembered position and size a moment
*after* the window appears, asynchronously, silently winning the race against
the initial layout. There is no signal to wait for here, so a newly opened
window is re-laid-out a couple of times over the first second after it opens.
This is the one place the product accepts fixed timing rather than waiting for
a settled state, and it applies only to windows that have just opened — never
to a drag or resize.

## 6. Floating windows

- A floating window is fully exempt from tiling: it keeps its own position and
  size, and no slot is reserved for it in the row.
- Floating is **sticky** — unlike the temporary exemptions during a drag, it
  persists until explicitly cleared.
- It is cleared by: toggling the shortcut again, dragging to the monitor's
  bottom edge again, cycling the window's width, or maximising it. The last
  two count as "the user has signalled they want it back in the row".
  Resizing a floating window by dragging its edge does **not** unfloat it —
  a floating window is meant to be sized freely, and the resize never drives
  a tiled neighbour the way a divider resize inside the row does.
- Floating a maximised window unmaximises it first, then shrinks and centres
  it like any other — a maximised floating window would just cover the row.
- A window that floats out of the row at full row height is shrunk to two
  thirds of the work-area height and centred vertically, so it visibly sits
  above the row rather than in it. Its width and horizontal position are
  kept. A window that was already shorter than full height keeps the height
  the user gave it.
- A floating window still participates in keyboard focus and reorder, and is
  skipped when a neighbour is needed for resize or width cycling (the same
  way a minimised or maximised neighbour already is).

## 7. Focus indicator

- The focused window is outlined with a highlighted border, so the user can
  always tell where focus is.
- The border uses the system accent colour from System Settings → Appearance,
  and updates live when that changes.
- The border is drawn **inside** the window's own bounds, so it stays fully
  visible even for a window filling the whole monitor.
- It follows the focused window as it moves and resizes.

### Identifying a floating window

A floating window is otherwise indistinguishable from a tiled one, so it is
marked:

- **Muted border** — when a floating window has focus, its border is drawn
  dashed and dimmed instead of solid, so the focus indicator itself says
  "this one isn't in the row".
- The mark appears the moment a window starts floating and disappears the
  moment it stops, however it was floated or unfloated.

A drop shadow was tried as a second, focus-independent mark and dropped: the
compositor's shadow effect paints around the window actor's bounds, which
include the client's own invisible shadow margins, so it rendered as a
detached box floating clear of the window edge.

## 8. Settings

- All settings live in one system-wide settings store shared by the plugin and
  its settings UI, so changes from either side are picked up by the other.
- Settings appear in **System Settings → Tiling**, installed alongside the
  plugin.
  - Shortcuts get a proper capture UI: click a row, press the combination.
    More than one combination per action is supported.
  - Exclusion lists are free-form comma-separated text fields.
- Everything is equally settable from the command line.

Settable:

- Each of the six shortcuts.
- Excluded window-title substrings (case-insensitive).
- Excluded application IDs.
- Minimum tileable window width/height.

## 9. Non-goals and known limitations

- **No horizontal scrolling / viewport.** When a row grows wider than the
  monitor, overflowing windows stack at the right edge rather than becoming
  pannable. This was attempted twice and reverted: the window manager offers
  no acceptable way to hide a window scrolled out of view, and the
  workarounds were worse than the overflow.
- No animation when windows are retiled; they snap into place.
- Connecting or disconnecting a monitor is not picked up live; the window
  manager must be restarted to get a row on a new monitor.
- Vertical stacking, columns, or multi-row layouts are out of scope.
- Workspace behaviour is out of scope.
- Built and verified against the elementaryOS 8-era window manager; other
  versions may need adjustment.

## 10. Quality expectations

- The layout must never leave a visible gap in the middle of a row.
- Windows must never be positioned outside their monitor. Because of that,
  a row wider than the monitor is allowed to overlap at the right edge — the
  accepted trade-off for having no viewport (section 9). Overlap must never
  happen in a row that *does* fit.
- A window must never be claimed by two rows at once, and must never be
  quietly stolen from the row it is in.
- No user action may result in a window being positioned off every monitor, or
  otherwise unreachable.
- The plugin must never take down the window manager. A failure should degrade
  to "layout stops helping", not "the session is unusable".
