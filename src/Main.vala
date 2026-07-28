namespace Gala.Plugins.Xy {
    public class Main : Gala.Plugin {
        private Gala.WindowManager? wm = null;
        private GLib.Settings settings;
        private FocusRing focus_ring;

        private Meta.WorkspaceManager? workspace_manager = null;
        private ulong workspace_added_id = 0;
        private ulong workspace_removed_id = 0;
        private ulong grab_op_begin_id = 0;
        private ulong grab_op_end_id = 0;
        private ulong do_focus_window_id = 0;

        private GLib.List<Row> rows = new GLib.List<Row> ();

        // Tracks the window we're waiting to "settle" after a drop: the
        // one whose row we've already re-homed it into, but which retile()
        // is still deliberately skipping because Row.grabbed_window is
        // still set. See restart_settle_timer().
        private unowned Meta.Window? settle_window = null;
        private unowned Row? settle_row = null;
        private uint settle_timeout_id = 0;

        // Divider-style resize: while the user interactively drags one edge
        // of a window that has a row-neighbor on that side, we mirror the
        // drag into the neighbor so the shared edge moves like elementary's
        // own snapped-window divider, instead of opening a gap or overlap.
        private const int MIN_DIVIDER_RESIZE_WIDTH = 50;
        // How close (px) a dropped window's frame bottom must land to its
        // monitor work area's bottom edge to count as a deliberate
        // drag-to-bottom-edge float toggle rather than an ordinary drop
        // elsewhere in the row. See dropped_on_bottom_edge().
        private const int FLOAT_EDGE_THRESHOLD = 12;
        private unowned Meta.Window? resize_window = null;
        private unowned Meta.Window? resize_partner = null;
        private int resize_delta = 0;
        // The partner's edge that must stay fixed while its facing edge
        // tracks the dragged window, captured once at grab-begin.
        private int resize_partner_far_x = 0;
        private ulong resize_size_changed_id = 0;
        // Guards against dereferencing a destroyed window mid-resize (e.g.
        // the neighbor closes while its edge is being dragged): both hooks
        // just call end_divider_resize(), which cleanly bails out once the
        // window it needs is gone (Row.force_remove_window() will already
        // have dropped a destroyed partner from its row by the time this
        // fires, so find_owning_row() in end_divider_resize() safely finds
        // nothing to retile).
        private ulong resize_window_unmanaged_id = 0;
        private ulong resize_partner_unmanaged_id = 0;

        public override void initialize (Gala.WindowManager wm) {
            this.wm = wm;
            settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");

            var display = wm.get_display ();
            workspace_manager = display.get_workspace_manager ();

            foreach (unowned var workspace in workspace_manager.get_workspaces ()) {
                track_workspace (workspace);
            }
            workspace_added_id = workspace_manager.workspace_added.connect ((index) => {
                var workspace = workspace_manager.get_workspace_by_index (index);
                if (workspace != null) {
                    track_workspace (workspace);
                }
            });
            workspace_removed_id = workspace_manager.workspace_removed.connect ((index) => {
                untrack_removed_workspaces (workspace_manager);
            });

            display.add_keybinding ("reorder-left", settings, Meta.KeyBindingFlags.NONE, on_reorder_left);
            display.add_keybinding ("reorder-right", settings, Meta.KeyBindingFlags.NONE, on_reorder_right);
            display.add_keybinding ("focus-left", settings, Meta.KeyBindingFlags.NONE, on_focus_left);
            display.add_keybinding ("focus-right", settings, Meta.KeyBindingFlags.NONE, on_focus_right);
            display.add_keybinding ("cycle-width", settings, Meta.KeyBindingFlags.NONE, on_cycle_width);
            display.add_keybinding ("toggle-floating", settings, Meta.KeyBindingFlags.NONE, on_toggle_floating);

            grab_op_begin_id = display.grab_op_begin.connect (on_grab_op_begin);
            grab_op_end_id = display.grab_op_end.connect (on_grab_op_end);
            do_focus_window_id = display.do_focus_window.connect (on_window_focused);

            focus_ring = new FocusRing (wm);
        }

        // Named handler with an explicitly nullable window, for the same
        // reason as the other do_focus_window/grab-op handlers below.
        // Lets each Row know which of its own windows was last worked on,
        // so a freshly opened window can be inserted next to it instead of
        // always at the tail (see Row.append()).
        private void on_window_focused (Meta.Display display, Meta.Window? window, int64 timestamp) {
            if (window == null) {
                return;
            }

            unowned var row = find_owning_row (window);
            if (row != null) {
                row.note_focus (window);
            }
        }

        private void track_workspace (Meta.Workspace workspace) {
            var display = wm.get_display ();
            var n_monitors = display.get_n_monitors ();

            for (int monitor = 0; monitor < n_monitors; monitor++) {
                if (find_row (workspace, monitor) == null) {
                    var geometry = display.get_monitor_geometry (monitor);
                    warning ("xy: track_workspace workspace_index=%d monitor=%d geometry=(%d,%d %dx%d) primary=%d",
                        workspace.index (), monitor, geometry.x, geometry.y, geometry.width, geometry.height,
                        display.get_primary_monitor ());
                    var row = new Row (workspace, monitor);
                    row.grabbed_window_churn.connect (on_grabbed_window_churn);
                    rows.append (row);
                } else {
                    warning ("xy: track_workspace workspace_index=%d monitor=%d row already exists, skipping",
                        workspace.index (), monitor);
                }
            }
        }

        // Rows are otherwise never torn down, so a Row's dynamically-created
        // workspace being destroyed by Mutter would leave it (and the strong
        // ref it holds via Row.workspace) tracked forever. Diffs `rows`
        // against the manager's own current list rather than trying to
        // match the removed index directly — workspace indices shift when
        // one is removed, so the index from the signal can't be mapped back
        // to a specific workspace reliably.
        private void untrack_removed_workspaces (Meta.WorkspaceManager workspace_manager) {
            unowned var live = workspace_manager.get_workspaces ();

            var stale = new GLib.List<weak Row> ();
            foreach (unowned var row in rows) {
                if (live.find (row.workspace) == null) {
                    stale.append (row);
                }
            }

            foreach (unowned var row in stale) {
                if (!row.is_empty ()) {
                    // Shouldn't happen: Mutter doesn't destroy a workspace
                    // that still has windows on it. Leave it tracked rather
                    // than risk tearing down a row whose windows still hold
                    // live signal connections into it.
                    warning ("xy: workspace removed but its row still holds windows, leaving it tracked");
                    continue;
                }

                row.teardown ();
                rows.remove (row);
            }
        }

        private unowned Row? find_row (Meta.Workspace workspace, int monitor) {
            foreach (unowned var row in rows) {
                if (row.workspace == workspace && row.monitor == monitor) {
                    return row;
                }
            }

            return null;
        }

        // Unlike find_row(), doesn't key off the window's live get_monitor()
        // — once a window is claimed by a Row, that ownership is
        // authoritative (see Row.claimed) and shouldn't be re-derived from
        // current screen position, which can transiently be wrong right
        // after a window is created. Keyboard actions on the focused
        // window should always resolve to whichever Row it actually
        // belongs to.
        private unowned Row? find_owning_row (Meta.Window window) {
            foreach (unowned var row in rows) {
                if (row.contains (window)) {
                    return row;
                }
            }

            return null;
        }

        // Named handler with an explicitly nullable window, for the same
        // reason as on_grab_op_end below.
        private void on_grab_op_begin (Meta.Display display, Meta.Window? window, Meta.GrabOp op) {
            if (window == null) {
                return;
            }

            if (op == Meta.GrabOp.MOVING || op == Meta.GrabOp.MOVING_UNCONSTRAINED) {
                // See Row.grabbed_window: while this is set, rows ignore
                // workspace add/remove churn for this window instead of
                // retiling it mid-drag and fighting the user's own movement.
                Row.grabbed_window = window;
                return;
            }

            if (Geometry.is_resize_op (op)) {
                // See Row.resize_window: exempts the window itself from
                // retile() for the whole grab, independent of whether
                // begin_divider_resize() below finds a neighbor to mirror
                // the drag into (e.g. a vertical-only or corner resize with
                // no usable partner on that side still needs this, or the
                // window's own live height change mid-drag would trigger a
                // stray retile that snaps it back into its row slot).
                Row.resize_window = window;
            }

            begin_divider_resize (window, op);
        }

        private void begin_divider_resize (Meta.Window window, Meta.GrabOp op) {
            int delta = Geometry.resize_delta_for_op (op);
            if (delta == 0) {
                return;
            }

            unowned var row = find_owning_row (window);
            if (row == null) {
                return;
            }

            unowned var partner = row.neighbor (window, delta);
            // Mirrors cycle_width()'s right_usable/left_usable checks: a
            // maximized neighbor is still kept in Row.order (retile() just
            // skips repositioning it), so row.neighbor() can hand back one
            // here. Driving move_resize_frame() on it directly would fight
            // Meta's own maximize state instead of the live drag mirroring
            // cleanly like it does for an ordinary tiled neighbor. Guarding
            // on minimized too even though a minimized window shouldn't be
            // in order at all (see track_minimized_state()) — cheap and
            // consistent with cycle_width()'s own belt-and-suspenders check.
            if (partner == null || partner.minimized || Row.is_floating (partner) ||
                partner.maximized_horizontally || partner.maximized_vertically) {
                return;
            }

            resize_window = window;
            resize_partner = partner;
            resize_delta = delta;
            // See Row.resize_partner: stops retile() from repositioning the
            // partner mid-drag, since we're already driving its frame here.
            Row.resize_partner = partner;

            var partner_frame = partner.get_frame_rect ();
            resize_partner_far_x = delta > 0 ? partner_frame.x + partner_frame.width : partner_frame.x;

            resize_size_changed_id = window.size_changed.connect (on_resize_window_size_changed);
            resize_window_unmanaged_id = window.unmanaged.connect (() => end_divider_resize ());
            resize_partner_unmanaged_id = partner.unmanaged.connect (() => end_divider_resize ());
        }

        // Mirrors the live drag into the partner: its facing edge tracks
        // the dragged edge exactly while its own far edge stays put, so the
        // shared boundary moves as one divider instead of opening a gap or
        // overlap between the two windows.
        private void on_resize_window_size_changed (Meta.Window window) {
            if (resize_partner == null) {
                return;
            }

            var frame = window.get_frame_rect ();
            var partner_frame = resize_partner.get_frame_rect ();

            int shared_edge_x = resize_delta > 0 ? frame.x + frame.width : frame.x;
            int new_x = resize_delta > 0 ? shared_edge_x : resize_partner_far_x;
            int new_width = resize_delta > 0
                ? resize_partner_far_x - shared_edge_x
                : shared_edge_x - resize_partner_far_x;

            if (new_width < MIN_DIVIDER_RESIZE_WIDTH) {
                return;
            }

            resize_partner.move_resize_frame (false, new_x, partner_frame.y, new_width, partner_frame.height);
        }

        private void end_divider_resize () {
            if (resize_window != null && resize_size_changed_id != 0) {
                resize_window.disconnect (resize_size_changed_id);
            }
            if (resize_window != null && resize_window_unmanaged_id != 0) {
                resize_window.disconnect (resize_window_unmanaged_id);
            }
            if (resize_partner != null && resize_partner_unmanaged_id != 0) {
                resize_partner.disconnect (resize_partner_unmanaged_id);
            }

            Row.resize_partner = null;

            // Final settle: the partner's frame is already correct from the
            // live drag, but a retile re-derives every window's x offset in
            // case rounding left the row's internal bookkeeping slightly off.
            // If the partner was destroyed mid-resize, Row.append()'s own
            // unmanaged hook has already dropped it from its row by the
            // time this runs, so find_owning_row() safely finds nothing.
            if (resize_partner != null) {
                unowned var row = find_owning_row (resize_partner);
                if (row != null) {
                    row.retile ();
                }
            }

            resize_window = null;
            resize_partner = null;
            resize_delta = 0;
            resize_partner_far_x = 0;
            resize_size_changed_id = 0;
            resize_window_unmanaged_id = 0;
            resize_partner_unmanaged_id = 0;
        }

        // Named handler with an explicitly nullable window: the vapi
        // declares this signal's window argument as non-null, so a lambda
        // here would get Vala's auto-inserted `window != NULL` assertion
        // and crash on any grab-op-end where Mutter passes a null window.
        private void on_grab_op_end (Meta.Display display, Meta.Window? window, Meta.GrabOp op) {
            if (resize_window != null) {
                end_divider_resize ();
            }

            // See Row.resize_window: clear the exemption now that the grab
            // is over, and force one more retile so the window snaps fully
            // into its row slot — needed even when there was no divider
            // partner at all (e.g. a vertical-only or corner resize that
            // begin_divider_resize() found no neighbor for).
            if (Row.resize_window != null && Row.resize_window == window) {
                unowned var resized = Row.resize_window;
                Row.resize_window = null;

                unowned var row = find_owning_row (resized);
                if (row != null) {
                    row.retile ();
                }
            }

            if (window == null) {
                Row.grabbed_window = null;
                Row.resize_window = null;
                return;
            }

            if (op != Meta.GrabOp.MOVING && op != Meta.GrabOp.MOVING_UNCONSTRAINED) {
                Row.grabbed_window = null;
                return;
            }

            // Deferred to idle: Gala/Pantheon's own edge-tiling and
            // move-between-monitor logic also reacts to grab-op-end and
            // can still be mid-animation here. Running our retile in the
            // same tick was fighting that and causing a visible flicker
            // right after drop; letting it settle first avoids the fight.
            GLib.Idle.add (() => {
                if (dropped_on_bottom_edge (window)) {
                    // A deliberate drag to the bottom edge toggles floating
                    // instead of an ordinary re-home: no cross-row move, no
                    // settle wait, just flip the flag and let Row.retile()
                    // (queued by set_floating()) react.
                    Row.grabbed_window = null;
                    toggle_floating (window);
                    return GLib.Source.REMOVE;
                }

                unowned var target = on_window_dropped (window);
                settle_window = window;
                settle_row = target;
                restart_settle_timer ();
                return GLib.Source.REMOVE;
            });
        }

        // Proxies "the user dragged this window to the bottom edge" off
        // where the window's frame actually rests after the drop, rather
        // than live pointer position — see Geometry.is_dropped_near_bottom_edge().
        private bool dropped_on_bottom_edge (Meta.Window window) {
            unowned var workspace = window.get_workspace ();
            if (workspace == null) {
                return false;
            }

            int monitor = monitor_for_window (window);
            var area = workspace.get_work_area_for_monitor (monitor);
            var frame = window.get_frame_rect ();

            return Geometry.is_dropped_near_bottom_edge (
                frame.y, frame.height, area.y, area.height, FLOAT_EDGE_THRESHOLD);
        }

        private void toggle_floating (Meta.Window window) {
            unowned var row = find_owning_row (window);
            if (row == null) {
                return;
            }

            row.set_floating (window, !Row.is_floating (window));
            // The toggled window is usually the focused one, so the ring is
            // already tracking it and won't be re-styled by a focus change.
            focus_ring.refresh_floating_state ();
        }

        private void on_toggle_floating (Meta.Display display, Meta.Window? window, Clutter.KeyEvent? event,
            Meta.KeyBinding binding) {
            unowned var focused = display.get_focus_window ();
            if (focused != null) {
                toggle_floating (focused);
            }
        }

        // Row.grabbed_window deliberately stays set through on_window_dropped
        // and beyond: Mutter's workspace add/remove churn for the dropped
        // window keeps firing for a while *after* grab-op-end too, not just
        // during the live drag, and would otherwise still fight our own
        // re-homing. Rather than guessing a fixed grace period, each row
        // reports every churn event it ignores (grabbed_window_churn); we
        // only declare things settled once a short quiet period passes with
        // no further churn at all, restarting the wait on every event.
        private void on_grabbed_window_churn (Meta.Window window) {
            if (window == settle_window) {
                restart_settle_timer ();
            }
        }

        private void restart_settle_timer () {
            if (settle_timeout_id != 0) {
                GLib.Source.remove (settle_timeout_id);
            }

            settle_timeout_id = GLib.Timeout.add (120, () => {
                settle_timeout_id = 0;

                if (Row.grabbed_window == settle_window) {
                    Row.grabbed_window = null;
                }

                // retile() deliberately skips moving the still-grabbed
                // window (see Row.retile()), so once it's no longer exempt
                // nothing else would ever pull it into the row's actual
                // layout — force one more retile now that churn has quieted.
                if (settle_row != null) {
                    settle_row.retile ();
                }

                settle_window = null;
                settle_row = null;
                return GLib.Source.REMOVE;
            });
        }

        private unowned Row? on_window_dropped (Meta.Window window) {
            unowned var workspace = window.get_workspace ();
            int monitor = monitor_for_window (window);

            unowned var target = find_row (workspace, monitor);

            // The window may have been dropped on a different monitor and/or
            // workspace than the row it was tracked under: move it to the
            // right row first. Checked across every row, not just ones on
            // the new workspace — a drag that also changes workspace fires
            // the old workspace's window_removed while Row.grabbed_window is
            // still set, which remove_window() deliberately ignores (see
            // Row.grabbed_window), so the old row never lets go of the
            // window on its own. Without this, the window stays in
            // Row.claimed forever and can never be tiled again anywhere.
            // (Deliberately not done on window_entered_monitor, which fires
            // continuously mid-drag as the pointer crosses the boundary —
            // retiling there fought the live drag and caused flicker.)
            foreach (unowned var row in rows) {
                if (row != target && row.contains (window)) {
                    row.force_remove_window (window);
                }
            }

            if (target != null) {
                if (!target.contains (window)) {
                    target.force_add_window (window);
                }
                target.reorder_by_position (window);
            }

            return target;
        }

        // Meta.Window.get_monitor() proved unreliable immediately after a
        // drag: logged values flip between the pre-drag and post-drag
        // monitor across otherwise-identical drops, even after deferring to
        // idle. Computing it ourselves from the window's actual current
        // frame center against each monitor's real geometry sidesteps
        // whatever internal bookkeeping lag causes that.
        private int monitor_for_window (Meta.Window window) {
            var display = wm.get_display ();
            var frame = window.get_frame_rect ();
            int center_x = frame.x + frame.width / 2;
            int center_y = frame.y + frame.height / 2;

            for (int i = 0; i < display.get_n_monitors (); i++) {
                var geometry = display.get_monitor_geometry (i);
                if (center_x >= geometry.x && center_x < geometry.x + geometry.width &&
                    center_y >= geometry.y && center_y < geometry.y + geometry.height) {
                    return i;
                }
            }

            return display.get_primary_monitor ();
        }

        private void on_reorder_left (Meta.Display display, Meta.Window? window, Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            reorder (display.get_focus_window (), -1);
        }

        private void on_reorder_right (Meta.Display display, Meta.Window? window, Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            reorder (display.get_focus_window (), 1);
        }

        private void on_focus_left (Meta.Display display, Meta.Window? window, Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            focus_neighbor (display.get_focus_window (), -1);
        }

        private void on_focus_right (Meta.Display display, Meta.Window? window, Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            focus_neighbor (display.get_focus_window (), 1);
        }

        private void on_cycle_width (Meta.Display display, Meta.Window? window, Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            cycle_width (display.get_focus_window ());
        }

        // window comes from Meta.Display.get_focus_window(), which the vapi
        // declares non-null but is null whenever nothing has focus.
        private void reorder (Meta.Window? window, int delta) {
            if (window == null) {
                return;
            }

            unowned var row = find_owning_row (window);
            if (row != null) {
                row.move (window, delta);
            }
        }

        private void focus_neighbor (Meta.Window? window, int delta) {
            if (window == null) {
                return;
            }

            unowned var row = find_owning_row (window);
            if (row == null) {
                return;
            }

            unowned var target = row.neighbor_wrapping (window, delta);
            if (target != null) {
                target.activate (wm.get_display ().get_current_time ());
            }
        }

        private void cycle_width (Meta.Window? window) {
            if (window == null) {
                return;
            }

            unowned var row = find_owning_row (window);
            if (row != null) {
                row.cycle_width (window);
            }
        }

        // Disconnects every signal this plugin connected on Meta.Display/
        // Meta.WorkspaceManager and shuts down every remaining Row, not just
        // already-empty ones (see Row.teardown()). At session logout every
        // workspace still has windows on it, so untrack_removed_workspaces()
        // alone never reaches them — leaving their hooks connected let this
        // plugin's callbacks fire mid meta_display_close, reaching into
        // windows/workspaces Mutter was already tearing down (root cause of
        // the gala segfault-on-logout this fixed).
        public override void destroy () {
            var display = wm.get_display ();
            display.remove_keybinding ("reorder-left");
            display.remove_keybinding ("reorder-right");
            display.remove_keybinding ("focus-left");
            display.remove_keybinding ("focus-right");
            display.remove_keybinding ("cycle-width");
            display.remove_keybinding ("toggle-floating");

            if (resize_window != null) {
                end_divider_resize ();
            }

            if (grab_op_begin_id != 0) {
                display.disconnect (grab_op_begin_id);
                grab_op_begin_id = 0;
            }
            if (grab_op_end_id != 0) {
                display.disconnect (grab_op_end_id);
                grab_op_end_id = 0;
            }
            if (do_focus_window_id != 0) {
                display.disconnect (do_focus_window_id);
                do_focus_window_id = 0;
            }

            if (workspace_manager != null) {
                if (workspace_added_id != 0) {
                    workspace_manager.disconnect (workspace_added_id);
                    workspace_added_id = 0;
                }
                if (workspace_removed_id != 0) {
                    workspace_manager.disconnect (workspace_removed_id);
                    workspace_removed_id = 0;
                }
            }

            if (settle_timeout_id != 0) {
                GLib.Source.remove (settle_timeout_id);
                settle_timeout_id = 0;
            }

            foreach (unowned var row in rows) {
                row.teardown ();
            }
            rows = new GLib.List<Row> ();

            focus_ring.destroy ();
        }
    }
}

public Gala.PluginInfo register_plugin () {
    return Gala.PluginInfo () {
        name = "xy",
        author = "Sander van Dragt",
        plugin_type = typeof (Gala.Plugins.Xy.Main),
        provides = Gala.PluginFunction.ADDITION,
        load_priority = Gala.LoadPriority.IMMEDIATE
    };
}
