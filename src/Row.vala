namespace Gala.Plugins.Xy {
    /*
     * Keeps one workspace's normal windows tiled edge-to-edge in a single
     * horizontal row, each window full height. Order is whatever the user
     * has arranged via keyboard reorder or drag-and-drop, not stacking order.
     */
    public class Row : GLib.Object {
        // Mirrors Main's MIN_DIVIDER_RESIZE_WIDTH: the floor cycle_width()
        // will shrink the neighbor absorbing the resize down to, same as
        // the live divider-drag path.
        private const int MIN_NEIGHBOR_WIDTH = 50;

        public Meta.Workspace workspace { get; construct; }
        // Which physical monitor this row tiles onto. A workspace gets one
        // Row per monitor since PaperWM-style tiling is inherently per-screen
        // (there's no single shared work area to lay windows out across).
        public int monitor { get; construct; }

        // Set by Main while a window is under an active interactive
        // move/resize grab. Mutter fires real workspace.window_added/
        // window_removed signals repeatedly *during* a live cross-monitor
        // drag (not just once at drop) as the window crosses the boundary —
        // reacting to those by retiling was fighting the user's own drag in
        // real time, which is what caused the flicker/snap-back-to-origin
        // behaviour. While a window is grabbed we ignore workspace signals
        // for it entirely and let Main's grab-op-end handling re-home it
        // once, after the drag genuinely finishes.
        //
        // Private with accessors, unlike the plain field this used to be, so
        // setting it can't fall out of step with the `driven` exemption
        // below — every move grab needs both, and there are half a dozen
        // assignment sites in Main.
        private static unowned Meta.Window? grabbed_window = null;

        public static unowned Meta.Window? get_grabbed_window () {
            return grabbed_window;
        }

        public static void set_grabbed_window (Meta.Window? window) {
            if (grabbed_window != null) {
                set_driven (grabbed_window, false);
            }

            grabbed_window = window;

            if (window != null) {
                set_driven (window, true);
            }
        }

        // Windows whose frame Main is driving directly right now, so
        // retile() must leave them exactly where they are. Three cases, all
        // the same rule ("don't fight the pointer", SPEC.md section 5) and
        // previously three separate statics:
        //
        //  - the window under a live move grab (also grabbed_window above,
        //    which stays separate because suppressing workspace churn is a
        //    question about that one specific window, not about exemption);
        //  - the window under a live resize grab, including vertical-only
        //    and corner resizes with no row-neighbor to mirror into — a
        //    stray retile mid-drag (e.g. correct_height_mismatch() reacting
        //    to the window's own live height change) would otherwise snap
        //    it back into its slot;
        //  - the row-neighbor being mirrored into during a divider resize,
        //    whose frame Main drives to keep it glued to the dragged edge.
        //
        // All three keep their slot in `order` — unlike `floating` below,
        // which is exempt *and* gives up its slot.
        private static GLib.List<weak Meta.Window> driven = new GLib.List<weak Meta.Window> ();

        public static void set_driven (Meta.Window window, bool value) {
            if (value) {
                if (driven.find (window) == null) {
                    driven.append (window);
                }
            } else {
                driven.remove (window);
            }
        }

        public static bool is_driven (Meta.Window window) {
            return driven.find (window) != null;
        }

        // Windows currently floating: excluded from this row's tiling
        // entirely — retile() skips them with no slot reserved, so
        // neighbors close the gap immediately — until explicitly unfloated
        // (dragging to the bottom edge again, cycling width, or
        // maximizing). Static like grabbed_window/claimed: floating is a
        // property of the window, not of whichever Row currently owns it,
        // so it survives the window being re-homed to a different row
        // (e.g. dragged to another monitor while floating).
        private static GLib.List<weak Meta.Window> floating = new GLib.List<weak Meta.Window> ();

        public static bool is_floating (Meta.Window window) {
            return floating.find (window) != null;
        }

        // A maximized window fills its monitor by design, overlapping the
        // rest of the row: retile() leaves it where it is, cycle_width()
        // unmaximizes instead of resizing it, and no resize mirrors into it.
        // Meta.Window.is_maximized() isn't in the vapi under HAS_MUTTER46,
        // hence the two-flag check — kept in one place so the several
        // callers can't drift apart on what "maximized" means.
        public static bool is_maximized (Meta.Window window) {
            return window.maximized_horizontally || window.maximized_vertically;
        }

        // Whether a row-neighbor can absorb the other side of a resize —
        // shared by cycle_width() and Main's divider-drag handling, which
        // must agree on this or the same neighbor would be driven by one
        // and refused by the other. A floating or maximized neighbor is
        // still in `order` (retile() just skips repositioning it), so
        // neighbor() can hand one back here; driving its frame directly
        // would fight the state the user put it in. Minimized windows
        // shouldn't be in `order` at all (see track_minimized_state()) —
        // checked anyway, cheaply.
        public static bool is_usable_neighbor (Meta.Window? window) {
            return window != null && !window.minimized && !is_floating (window) && !is_maximized (window);
        }

        // Static across every Row: every window currently claimed by any
        // row, by identity. Once a window is claimed, its row membership
        // is authoritative and is NOT re-derived from live get_monitor()
        // the way initial placement is — a window can transiently report
        // the wrong monitor for a tick or two right after creation, and
        // without this a later stray workspace signal could get it
        // re-evaluated and stolen by a different row. This is the same
        // principle as grabbed_window above, generalized from "the one
        // window being actively dragged" to "any window a Row already owns".
        private static GLib.List<weak Meta.Window> claimed = new GLib.List<weak Meta.Window> ();

        // Fired whenever a workspace add/remove signal for grabbed_window
        // was ignored. Main listens for this to know the churn hasn't
        // settled yet, rather than guessing a fixed quiet period.
        public signal void grabbed_window_churn (Meta.Window window);

        private GLib.List<weak Meta.Window> order = new GLib.List<weak Meta.Window> ();
        // The last window in this row to receive focus. New windows are
        // inserted right after it in `order` (see append()) rather than
        // always at the tail, so a freshly opened window lands next to
        // whatever you were actually working on, not necessarily at the
        // end of the row.
        private unowned Meta.Window? last_focused = null;
        // Windows we've already hooked notify::minimized on, so a window
        // that starts minimized (e.g. CopyQ, which spends most of its life
        // iconified and only briefly shown via its own global hotkey) still
        // gets pulled into the row once it's shown, and drops back out the
        // moment it's hidden again — not just checked once at add time.
        private GLib.List<weak Meta.Window> minimize_tracked = new GLib.List<weak Meta.Window> ();
        // Windows we've already hooked size_changed on so a window rejected
        // at add time for being below min-tileable-size (a small popup,
        // e.g.) still joins the row if it's later resized past the
        // threshold — is_tileable() was otherwise only ever re-checked at
        // add time, on notify::title, or when the exclusion settings
        // themselves change (reevaluate_exclusions()), never on the
        // window's own live size.
        private GLib.List<weak Meta.Window> size_tracked = new GLib.List<weak Meta.Window> ();
        // Windows already hooked with append()'s per-window lifecycle
        // signals (unmanaged, size_changed, maximized/title notifies).
        // append() itself is called on every re-add of a window that's
        // left and rejoined the row — e.g. every minimize/restore cycle
        // via track_minimized_state() — not just the first time it's ever
        // tiled, so without this guard those hooks would be reconnected
        // (and pile up, one full set per cycle) each time a long-lived
        // window like CopyQ is shown again.
        private GLib.List<weak Meta.Window> lifecycle_tracked = new GLib.List<weak Meta.Window> ();
        private bool retile_queued = false;
        private bool retiling = false;
        // Set by teardown() during full plugin shutdown (Main.destroy()) so
        // every entry point that touches a Meta.Window/Workspace or
        // schedules more work becomes a no-op. Needed because at shutdown
        // every workspace still has windows on it, so this row's
        // window_added/removed and per-window (unmanaged/size_changed/
        // notify) hooks stay connected — Mutter's own teardown
        // (meta_display_close) fires them mid-dispose, and without this
        // guard those handlers would call back into windows/workspaces
        // Mutter is actively destroying.
        private bool shutting_down = false;

        private ulong window_added_id = 0;
        private ulong window_removed_id = 0;
        private ulong excluded_title_keywords_changed_id = 0;
        private ulong excluded_app_ids_changed_id = 0;
        private ulong min_tileable_size_changed_id = 0;

        // Investigation-only identity markers (see id below): logging
        // title alone can't tell two same-titled windows or two Row
        // instances for the same monitor apart.
        private static int next_id = 0;
        private int id;

        public Row (Meta.Workspace workspace, int monitor) {
            Object (workspace: workspace, monitor: monitor);
        }

        construct {
            id = next_id++;
            window_added_id = workspace.window_added.connect (add_window);
            window_removed_id = workspace.window_removed.connect (remove_window);

            // Without this, editing excluded-title-keywords/excluded-app-ids
            // (via `gsettings set` or the Switchboard plug) has no effect on
            // windows already tiled or already excluded — is_tileable() was
            // otherwise only ever re-checked on add, or on a window's own
            // notify::title/notify::minimized, never on the exclusion lists
            // themselves changing.
            excluded_title_keywords_changed_id = get_exclusion_settings ()
                .changed["excluded-title-keywords"].connect (() => reevaluate_exclusions ());
            excluded_app_ids_changed_id = get_exclusion_settings ()
                .changed["excluded-app-ids"].connect (() => reevaluate_exclusions ());
            min_tileable_size_changed_id = get_exclusion_settings ()
                .changed["min-tileable-size"].connect (() => reevaluate_exclusions ());

            warning ("xy: Row#%d construct monitor=%d workspace_index=%d", id, monitor, workspace.index ());

            foreach (unowned var window in workspace.list_windows ()) {
                add_window (window);
            }
        }

        // Re-derives chrome exclusion for every window on this row's own
        // monitor against the (just-changed) gsettings lists: evicts
        // anything already tiled that should now be excluded, and offers
        // anything not yet claimed a chance to be added in case it should
        // now be tileable. add_window() already no-ops safely on a window
        // this row doesn't own or that's claimed elsewhere.
        private void reevaluate_exclusions () {
            foreach (unowned var window in workspace.list_windows ()) {
                if (window.get_monitor () != monitor) {
                    continue;
                }

                if (contains (window) && !is_tileable (window)) {
                    force_remove_window (window);
                } else if (!contains (window)) {
                    add_window (window);
                }
            }
        }

        public bool contains (Meta.Window window) {
            return order.find (window) != null;
        }

        public bool is_empty () {
            return order.length () == 0;
        }

        // Called by Main either when this row's workspace has been destroyed
        // by Mutter (workspace_removed, only for an empty row — see
        // is_empty()) or unconditionally on every remaining row during
        // plugin shutdown (Main.destroy()). Disconnects this row's own
        // workspace-level signals and marks it shutting_down so every other
        // entry point (add_window, retile, etc.) becomes a no-op instead of
        // reaching into windows/workspaces Mutter may already be tearing
        // down. Without the workspace_removed case, `workspace` (an owned,
        // not weak, property) would keep a dead workspace alive forever, and
        // `rows`/`claimed` would grow without bound as dynamic workspaces
        // come and go.
        public void teardown () {
            if (shutting_down) {
                return;
            }
            shutting_down = true;

            if (window_added_id != 0) {
                workspace.disconnect (window_added_id);
                window_added_id = 0;
            }

            if (window_removed_id != 0) {
                workspace.disconnect (window_removed_id);
                window_removed_id = 0;
            }

            if (excluded_title_keywords_changed_id != 0) {
                get_exclusion_settings ().disconnect (excluded_title_keywords_changed_id);
                excluded_title_keywords_changed_id = 0;
            }

            if (excluded_app_ids_changed_id != 0) {
                get_exclusion_settings ().disconnect (excluded_app_ids_changed_id);
                excluded_app_ids_changed_id = 0;
            }

            if (min_tileable_size_changed_id != 0) {
                get_exclusion_settings ().disconnect (min_tileable_size_changed_id);
                min_tileable_size_changed_id = 0;
            }
        }

        // Called by Main whenever a window belonging to this row receives
        // focus, so append() knows where "the window I was working with"
        // currently is.
        public void note_focus (Meta.Window window) {
            last_focused = window;
        }

        // Toggled by Main, either from the toggle-floating keybinding or a
        // drag dropped on the monitor's bottom edge. Forces a retile either
        // way: turning floating on needs neighbors to immediately close the
        // gap this window's slot leaves behind; turning it off needs the
        // window snapped back into its slot.
        public void set_floating (Meta.Window window, bool value) {
            if (value == is_floating (window)) {
                return;
            }

            if (value) {
                floating.append (window);
                shrink_on_float (window);
            } else {
                floating.remove (window);
            }

            floating_changed (window);
            queue_retile ();
        }

        // Emitted on every floating state change, including the indirect
        // ones (width cycling, maximizing) that don't go through Main's
        // toggle. Main uses it to restyle the focus ring, which marks a
        // floating window with a dashed border.
        public signal void floating_changed (Meta.Window window);

        // How tall a window is made when it floats out of the row, as a
        // fraction of the monitor work area, and how many px short of full
        // height still counts as "full height" (a frame can sit a pixel or
        // two off after a retile).
        private const double FLOAT_HEIGHT_FRACTION = 2.0 / 3.0;
        private const int FLOAT_HEIGHT_TOLERANCE = 8;

        // See Geometry.float_shrink_geometry(): a just-floated window that
        // still fills the row's full height doesn't look lifted out, so
        // shrink it vertically and centre it. Width and x are left as they
        // are — the window keeps its column position in the row it came
        // from, which is where the user expects to find it.
        private void shrink_on_float (Meta.Window window) {
            // A maximized window is pinned to the monitor by Mutter, so
            // resizing it here would be reverted and it would sit there as a
            // full-screen "floating" window. Unmaximize first — but its
            // frame rect only reports the restored geometry once Mutter has
            // processed that, so do the shrink on the next idle instead of
            // against the stale full-monitor rect. The local strong ref
            // keeps the window alive for the closure; the floating re-check
            // covers it being unfloated again in between.
            if (is_maximized (window)) {
                Meta.Window pending = window;
                pending.unmaximize (Meta.MaximizeFlags.BOTH);
                GLib.Idle.add (() => {
                    if (!shutting_down && is_floating (pending)) {
                        shrink_on_float (pending);
                    }

                    return GLib.Source.REMOVE;
                });
                return;
            }

            var area = workspace.get_work_area_for_monitor (monitor);
            var frame = window.get_frame_rect ();

            int new_height, new_y;
            if (!Geometry.float_shrink_geometry (frame.height, area.y, area.height, FLOAT_HEIGHT_FRACTION,
                FLOAT_HEIGHT_TOLERANCE, out new_height, out new_y)) {
                return;
            }

            window.move_resize_frame (false, frame.x, new_y, frame.width, new_height);
        }

        // No drop shadow is applied to a floating window, even though
        // "elevation" would be the obvious visual cue. Gala.ShadowEffect
        // paints around the *actor's* bounds, and a window actor's bounds
        // include the client's own invisible CSD shadow margins — so the
        // shadow rendered as a detached rounded box with a gap between it
        // and the visible window edge. Clutter effects have no way to inset
        // that to the frame rect, so the muted focus border in
        // FocusRing.vala is the only floating marker (see SPEC.md
        // "Identifying a floating window").

        // Backing store for excluded-app-ids/excluded-title-keywords (see
        // gschema). Lazily created rather than at field-init time: Row
        // instances (and FocusRing, via is_normal_app_window()) can be
        // constructed before GLib.Settings' schema source is guaranteed
        // ready, so the first real call is a safer place to open it.
        private static GLib.Settings? exclusion_settings = null;

        private static GLib.Settings get_exclusion_settings () {
            if (exclusion_settings == null) {
                exclusion_settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");
            }

            return exclusion_settings;
        }

        // Utils.get_window_is_normal() alone isn't enough: Wingpanel reports
        // as a normal window and would otherwise get tiled into the row at
        // full monitor width, pushing everything after it off the actual
        // monitor. Hard-exclude known system chrome by title instead of by
        // is_always_on_all_workspaces(): Pantheon's secondary-monitor-is-a-
        // shared-surface model means ordinary application windows opened
        // there can carry that same flag (it's how they stay put across
        // primary-monitor workspace switches), so using it to mean "system
        // chrome, don't tile" was excluding real windows, not just
        // Wingpanel/Plank. Shared with FocusRing.track() so the two don't
        // drift: without this, an excluded window could still pick up a
        // focus-ring border even though Row refuses to tile it.
        //
        // Both lists come from gsettings (excluded-title-keywords,
        // excluded-app-ids) rather than being hardcoded, so excluding a
        // different panel/dock/plugin doesn't need a source change and
        // rebuild — see `gsettings set
        // org.pantheon.desktop.gala.plugins.xy excluded-app-ids
        // "['some.app.id']"`.
        public static bool is_chrome_window (Meta.Window window) {
            var settings = get_exclusion_settings ();

            string title = window.get_title ().down ();
            foreach (unowned string keyword in settings.get_strv ("excluded-title-keywords")) {
                if (keyword != "" && title.contains (keyword.down ())) {
                    return true;
                }
            }

            // Sidewing (the default excluded-app-ids entry) has more than
            // one window (its main bar, plus a per-plugin Variables Editor
            // dialog) and only the bar's title actually contains
            // "sidewing" — the editor's title is just "Variables — <plugin
            // name>". Matching by app ID instead of title excludes every
            // one of an app's windows, not just whichever one happens to
            // have a matching title.
            string? app_id = window.get_gtk_application_id ();
            if (app_id != null) {
                foreach (unowned string excluded_id in settings.get_strv ("excluded-app-ids")) {
                    if (app_id == excluded_id) {
                        return true;
                    }
                }
            }

            return false;
        }

        // Shared with FocusRing.track() — see is_chrome_window().
        public static bool is_normal_app_window (Meta.Window window) {
            return Utils.get_window_is_normal (window) && !is_chrome_window (window);
        }

        // Small popups/confirmation dialogs (e.g. an auth prompt or a
        // save-changes confirmation) report as normal windows but shouldn't
        // be forced edge-to-edge into the row — min-tileable-size (gschema,
        // default 150px) is a floor on both dimensions, not just one, since
        // a narrow-but-tall or wide-but-short window is just as much a
        // popup as a small square one.
        private bool is_tileable (Meta.Window window) {
            if (!is_normal_app_window (window) || window.minimized) {
                return false;
            }

            var frame = window.get_frame_rect ();
            int min_size = get_exclusion_settings ().get_int ("min-tileable-size");
            return frame.width >= min_size && frame.height >= min_size;
        }

        // See size_tracked: hooks size_changed once per window so a window
        // currently too small to tile still joins the row later if it grows
        // past min-tileable-size.
        private void track_size_state (Meta.Window window) {
            if (size_tracked.find (window) != null) {
                return;
            }

            size_tracked.append (window);
            window.size_changed.connect (() => {
                if (!contains (window) && window.get_monitor () == monitor && window.get_workspace () == workspace) {
                    add_window (window);
                }
            });
        }

        // See minimize_tracked: hooks notify::minimized once per window so
        // a currently-minimized (but otherwise tileable) window still joins
        // the row later if it's ever shown, and drops out again the moment
        // it's re-hidden.
        private void track_minimized_state (Meta.Window window) {
            if (minimize_tracked.find (window) != null) {
                return;
            }

            minimize_tracked.append (window);
            window.notify["minimized"].connect (() => {
                if (window.minimized) {
                    force_remove_window (window);
                } else if (is_tileable (window) && window.get_monitor () == monitor && window.get_workspace () == workspace && !contains (window)) {
                    append (window);
                }
            });
        }

        // The two hooks that let a window this row currently *refuses* still
        // join later — minimized→shown, and grown past min-tileable-size.
        // Both add paths need them, and force_add_window() used to wire only
        // the first: a window re-homed here by a drag never got the size
        // hook, so if it was dropped while below the threshold it could
        // never join the row by growing.
        private void track_window_state (Meta.Window window) {
            track_minimized_state (window);
            track_size_state (window);
        }

        public void add_window (Meta.Window window) {
            if (shutting_down) {
                return;
            }

            if (window == grabbed_window) {
                grabbed_window_churn (window);
                return;
            }

            // Already owned by some Row — possibly this one (about to be
            // caught by contains() below anyway), possibly another. Either
            // way, ownership is already decided; don't re-derive it from
            // this window's current get_monitor(), which may no longer
            // reflect where it logically belongs (see `claimed` above).
            if (claimed.find (window) != null) {
                return;
            }

            track_window_state (window);

            warning ("xy: Row#%d add_window check title=%s seq=%u row_monitor=%d window.get_monitor=%d tileable=%s workspace_index=%d",
                id, window.get_title (), window.get_stable_sequence (), monitor, window.get_monitor (),
                is_tileable (window).to_string (), workspace.index ());

            if (!is_tileable (window) || window.get_monitor () != monitor || window.get_workspace () != workspace || contains (window)) {
                return;
            }

            warning ("xy: Row#%d add_window ACCEPTED title=%s seq=%u monitor=%d", id, window.get_title (), window.get_stable_sequence (), monitor);
            append (window);
        }

        // Used when the caller has already determined this window belongs
        // on this row's monitor by some means other than
        // Meta.Window.get_monitor() — e.g. after a drag, where get_monitor()
        // has proven unreliable for a tick or two. Skips add_window()'s own
        // (redundant, and in that case wrong) monitor re-check.
        public void force_add_window (Meta.Window window) {
            if (shutting_down) {
                return;
            }

            track_window_state (window);

            if (!is_tileable (window) || contains (window)) {
                return;
            }

            append (window);
        }

        private void append (Meta.Window window) {
            if (shutting_down) {
                return;
            }

            // New windows land right after whichever window was last
            // focused in this row, not always at the tail — that's "to the
            // right of the window I was working with", which for a
            // reordered row isn't necessarily the same slot as the end.
            int insert_at = -1;
            if (last_focused != null) {
                int index = order.index (last_focused);
                if (index >= 0) {
                    insert_at = index + 1;
                }
            }

            order.insert (window, insert_at);
            claimed.append (window);

            // Guard: append() runs again on every re-add of a window that's
            // left and rejoined this row (e.g. a minimize/restore cycle via
            // track_minimized_state()), not just the first time it's ever
            // tiled. Only wire these up once per window's lifetime, or a
            // long-lived window like CopyQ (which the min/restore comments
            // above already call out) accumulates a full duplicate set of
            // handlers every cycle.
            if (lifecycle_tracked.find (window) == null) {
                lifecycle_tracked.append (window);

                // Deliberately force_remove_window(), not remove_window():
                // the latter ignores the currently-grabbed window so
                // mid-drag workspace-membership churn doesn't fight the
                // drag (see grabbed_window), but unmanaged means the window
                // is actually gone for good — closing a window while
                // dragging it must still release it here, or it stays
                // claimed forever with nothing left to ever remove it.
                // Also drops it from lifecycle_tracked here specifically
                // (not in force_remove_window() itself, which also runs for
                // a plain minimize or a cross-monitor drag re-home, neither
                // of which destroys the window): this is the one path where
                // the window is actually gone for good, so it's the only
                // place this list should be pruned.
                window.unmanaged.connect (() => {
                    lifecycle_tracked.remove (window);
                    // Same reasoning as lifecycle_tracked above: these lists
                    // exist only to guard against reconnecting the same
                    // one-time hook, not to reflect current row membership,
                    // so they must only ever be pruned here — when the
                    // window is actually gone for good — never in
                    // force_remove_window() (a plain minimize also calls
                    // that). Pruning them there used to make a minimized-
                    // then-re-evaluated window look "never tracked" to
                    // track_minimized_state()/track_size_state(), which
                    // reconnected a second handler on top of the still-live
                    // original one every such cycle.
                    minimize_tracked.remove (window);
                    size_tracked.remove (window);
                    floating.remove (window);
                    // A window closed mid-drag never reaches Main's
                    // grab-op-end clearing, and a stale entry here would
                    // exempt whatever object later lands at the same
                    // address from ever being retiled.
                    set_driven (window, false);
                    force_remove_window (window);
                });
                window.size_changed.connect (() => correct_height_mismatch (window));
                // A maximized window fills the monitor by design, overlapping
                // the rest of the row — retile() deliberately leaves it alone
                // while that's the case (see retile()). Once it's unmaximized
                // again it needs to snap back into its row slot, which nothing
                // else would trigger. Maximizing also unfloats: "resized or
                // maximized" both count as leaving the floating state, per
                // set_floating()'s callers.
                window.notify["maximized-horizontally"].connect (() => on_maximized_changed (window));
                window.notify["maximized-vertically"].connect (() => on_maximized_changed (window));
                // Some chrome (observed with sidewing) has no title yet at map
                // time, so is_tileable()'s title-based check above passes and
                // the window gets claimed. Once its real title lands, evict it
                // if it turns out to be chrome after all — retile() never
                // re-checks is_tileable() itself, it just tiles whatever is
                // already in order.
                window.notify["title"].connect (() => {
                    if (!is_tileable (window) && contains (window)) {
                        force_remove_window (window);
                    }
                });
            }
            warning ("xy: Row#%d append title=%s seq=%u monitor=%d new_order.length=%u",
                id, window.get_title (), window.get_stable_sequence (), monitor, order.length ());
            queue_retile ();
            schedule_new_window_settle_retiles ();
        }

        // Some apps (observed with Firefox and Files/Nautilus) restore their
        // own last-used position/size shortly after Gala maps the window —
        // asynchronously, after our one retile() in append() already ran.
        // That later self-reposition silently wins the race and the window
        // sits at its old spot until something else (e.g. cycle-width)
        // forces another retile. Rather than try to detect that specific
        // signal, just retile a couple more times shortly after add to
        // catch it landing late; retile() is a no-op move_resize_frame for
        // any window already in place, so the extra calls are cheap.
        private void schedule_new_window_settle_retiles () {
            GLib.Timeout.add (200, () => {
                queue_retile ();
                return GLib.Source.REMOVE;
            });
            GLib.Timeout.add (800, () => {
                queue_retile ();
                return GLib.Source.REMOVE;
            });
        }

        // Some windows — observed with a Firefox web-app window loading
        // Gmail — self-resize away from full row height sometime after
        // append()'s own settle retiles (schedule_new_window_settle_retiles)
        // have already run, e.g. once the page itself finishes loading.
        // Nothing else reacts to a window's own late size_changed, so
        // without this the window would be stuck short until some
        // unrelated retile (e.g. cycle-width) happened to fix it.
        // queue_retile() is cheap here since retile() no-ops a
        // move_resize_frame for any window already in place.
        private void correct_height_mismatch (Meta.Window window) {
            // A floating window is deliberately not full height (see
            // shrink_on_float()), so its every size change would otherwise
            // look like a mismatch worth logging and retiling for.
            if (shutting_down || !contains (window) || is_floating (window)) {
                return;
            }

            var area = workspace.get_work_area_for_monitor (monitor);
            var frame = window.get_frame_rect ();
            if (frame.height != area.height) {
                warning ("xy: Row#%d height_mismatch title=%s seq=%u expected_height=%d actual_height=%d y=%d",
                    id, window.get_title (), window.get_stable_sequence (), area.height, frame.height, frame.y);
                queue_retile ();
            }
        }

        private void on_maximized_changed (Meta.Window window) {
            if (is_floating (window) && is_maximized (window)) {
                set_floating (window, false);
            }

            queue_retile ();
        }

        public void remove_window (Meta.Window window) {
            if (shutting_down) {
                return;
            }

            if (window == grabbed_window) {
                grabbed_window_churn (window);
                return;
            }

            force_remove_window (window);
        }

        // Used when the caller (Main's drop re-homing) has decided this
        // window must leave this row right now, regardless of whether it's
        // the currently-grabbed window — unlike remove_window(), which
        // ignores the grabbed window so Mutter's spurious mid-drag
        // workspace signals don't touch it.
        public void force_remove_window (Meta.Window window) {
            if (shutting_down || !contains (window)) {
                return;
            }

            order.remove (window);
            claimed.remove (window);
            if (window == last_focused) {
                last_focused = null;
            }
            warning ("xy: Row#%d force_remove_window title=%s seq=%u monitor=%d new_order.length=%u",
                id, window.get_title (), window.get_stable_sequence (), monitor, order.length ());
            queue_retile ();
        }

        // The slot `delta` steps left (-1) or right (+1) of the given
        // window's own slot, or -1 if the window isn't in this row or the
        // step falls off an end. With wrap, an end step lands on the
        // opposite end instead: the row is a loop.
        private int step_index (Meta.Window window, int delta, bool wrap) {
            int index = order.index (window);
            int length = (int) order.length ();
            if (index < 0 || length == 0) {
                return -1;
            }

            int target = index + delta;

            if (wrap) {
                // GLib's % keeps the sign of the dividend, so a -1 step off
                // the left end needs the extra + length to land on the last
                // window rather than a negative index.
                return ((target % length) + length) % length;
            }

            return (target < 0 || target >= length) ? -1 : target;
        }

        // Move the focused window one slot left (-1) or right (+1). Stops at
        // either end — reordering deliberately doesn't wrap the way focus
        // does (SPEC.md section 5).
        public void move (Meta.Window window, int delta) {
            int target = step_index (window, delta, false);
            if (target < 0) {
                return;
            }

            order.remove (window);
            order.insert (window, target);
            queue_retile ();
        }

        // The window one slot left (-1) or right (+1) of the given window in
        // this row. Null at either end: used by the resize and cycle-width
        // paths, where "grow into the window on that side" must not reach
        // across the whole row to the far end.
        public unowned Meta.Window? neighbor (Meta.Window window, int delta) {
            int target = step_index (window, delta, false);

            return target < 0 ? null : order.nth_data (target);
        }

        // Like neighbor(), but wrapping around the ends of the row — right
        // of the last window is the first, and vice versa. Keyboard focus
        // uses this one; see move() on why reordering doesn't.
        public unowned Meta.Window? neighbor_wrapping (Meta.Window window, int delta) {
            int target = step_index (window, delta, true);

            return target < 0 ? null : order.nth_data (target);
        }

        // Cycle the focused window's width through fixed fractions of the
        // monitor's work area (1/3, 1/2, 2/3). Not tracked as state on the
        // window: each call re-derives the closest current fraction from
        // the window's actual live width and advances to the next one, so
        // a window resized some other way since the last cycle still
        // advances from wherever it visually is now.
        public void cycle_width (Meta.Window window) {
            if (!contains (window)) {
                return;
            }

            // Cycling width is one of the ways a floating window rejoins
            // the row's tiling (see set_floating()'s callers) — the rest of
            // this method then runs as normal, cycling from wherever the
            // window's frame currently sits.
            if (is_floating (window)) {
                set_floating (window, false);
            }

            // A maximized window's frame rect is the full monitor, not a
            // meaningful starting point for the fraction cycle, and retile()
            // leaves maximized windows alone anyway (see append()'s
            // maximized notify hooks). Unmaximizing snaps it back into its
            // row slot via that same hook instead of cycling its width here.
            if (is_maximized (window)) {
                window.unmaximize (Meta.MaximizeFlags.BOTH);
                return;
            }

            double[] fractions = { 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0 };
            var area = workspace.get_work_area_for_monitor (monitor);
            var frame = window.get_frame_rect ();

            int new_width = Geometry.next_fraction_width (frame.width, area.width, fractions);
            int delta = new_width - frame.width;

            // Mirror the resize into a neighbor the same way divider-drag
            // resize does (see Main's begin_divider_resize/
            // on_resize_window_size_changed): the neighbor's facing edge
            // tracks the shared boundary, its far edge stays put, so the
            // two windows' combined width is unchanged and they never
            // overlap or leave a gap. Prefer the right neighbor (grow this
            // window's right edge into it, keeping this window's own left
            // edge fixed); if there isn't a usable one — this is the last
            // window in the row — fall back to the left neighbor instead
            // (grow this window's left edge into it), since otherwise the
            // last window in a row would just overflow off the monitor
            // with nothing compensating at all.
            unowned var right = neighbor (window, 1);
            unowned var left = neighbor (window, -1);

            unowned Meta.Window? partner = null;
            // +1: the partner is on the right, so this window's left edge
            // stays put and the shared edge moves right. -1: mirrored, this
            // window's right edge stays put and the shared edge moves left.
            int side = 0;
            if (delta != 0 && is_usable_neighbor (right)) {
                partner = right;
                side = 1;
            } else if (delta != 0 && is_usable_neighbor (left)) {
                partner = left;
                side = -1;
            }

            if (partner == null) {
                window.move_resize_frame (false, frame.x, frame.y, new_width, frame.height);
                queue_retile ();
                return;
            }

            var partner_frame = partner.get_frame_rect ();

            // Cap the resize to whatever the neighbor can actually give up:
            // if shrinking it by the full delta would take it below the same
            // floor divider-drag enforces, shrink it only down to that floor
            // and grow this window by that reduced amount instead —
            // otherwise the two would overlap.
            int actual_delta = Geometry.cap_delta_to_min_width (partner_frame.width, delta, MIN_NEIGHBOR_WIDTH);

            if (actual_delta != 0) {
                window.move_resize_frame (false, side > 0 ? frame.x : frame.x - actual_delta, frame.y,
                    frame.width + actual_delta, frame.height);
                partner.move_resize_frame (false, side > 0 ? partner_frame.x + actual_delta : partner_frame.x,
                    partner_frame.y, partner_frame.width - actual_delta, partner_frame.height);
            }

            queue_retile ();
        }

        // Called after a drag finishes: re-derive the order from the
        // window's dropped x position relative to its row neighbors.
        public void reorder_by_position (Meta.Window window) {
            if (!contains (window)) {
                return;
            }

            order.sort ((a, b) => {
                var rect_a = a.get_frame_rect ();
                var rect_b = b.get_frame_rect ();
                return rect_a.x - rect_b.x;
            });

            queue_retile ();
        }

        // Coalesce retiling into an idle callback: window_added fires while
        // a window is still being constructed (its actor has no allocation
        // yet), and calling move_resize_frame() on it synchronously from
        // there was re-entering window_added before the first call
        // returned, recursing until the stack overflowed. Deferring to idle
        // lets the window finish construction first.
        private void queue_retile () {
            if (shutting_down || retile_queued) {
                return;
            }

            retile_queued = true;
            GLib.Idle.add (() => {
                retile_queued = false;
                retile ();
                return GLib.Source.REMOVE;
            });
        }

        public void retile () {
            // Belt-and-suspenders: move_resize_frame() can itself trigger
            // signals that lead back here before this call returns. Also
            // covers a retile already queued via GLib.Idle.add() before
            // shutting_down flipped true — it still runs once queued, this
            // just makes it a no-op instead of touching a window mid-Mutter-
            // teardown.
            if (shutting_down || retiling || order.length () == 0) {
                return;
            }

            retiling = true;

            var area = workspace.get_work_area_for_monitor (monitor);
            int max_x = area.x + area.width;
            warning ("xy: Row#%d retile monitor=%d workspace_index=%d area=(%d,%d %dx%d) order.length=%u",
                id, monitor, workspace.index (), area.x, area.y, area.width, area.height, order.length ());

            int x = area.x;
            order.foreach ((window) => {
                // Floating windows keep their row membership (so keyboard
                // reorder/focus/cycle-width still reach them) but are
                // otherwise invisible to layout: no slot reserved, no
                // repositioning, so neighbors tile edge-to-edge as if the
                // window wasn't in the row at all.
                if (is_floating (window)) {
                    return;
                }

                var frame = window.get_frame_rect ();

                // No scrolling viewport: a row wider than the monitor has
                // nowhere real to put the overflow. Clamping to the
                // monitor's right edge means overflowing windows stack on
                // top of each other there instead of the alternative,
                // which is landing on whatever lies in that physical
                // screen-coordinate range — the neighboring monitor's row,
                // or off every monitor entirely — and having Mutter
                // reassign their monitor to match, which is what was
                // happening before. A real scrolling viewport was tried
                // and reverted: Mutter refuses to place a window far
                // enough outside every monitor's bounds for off-screen
                // parking to work (confirmed live via wmctrl — it clamps
                // back to within ~10-75px of the work area regardless of
                // who asks, per constrain_partially_onscreen() in Mutter's
                // own constraints.c, which has no user-action bypass),
                // and minimizing out-of-view windows was rejected as a
                // replacement.
                int target_x = int.max (area.x, int.min (x, max_x - frame.width));
                bool maximized = is_maximized (window);

                // Still counts toward layout (it keeps its slot in the
                // row), but skip actually moving it: retile() can run for
                // reasons unrelated to this specific window (e.g. another
                // window in the same row being added/removed) while it's
                // mid-drag, and repositioning it would fight the user's
                // own live movement the same way reacting to the mid-drag
                // workspace signals did. A maximized window is left alone
                // too — it's meant to fill the monitor, overlapping the
                // rest of the row, and forcing it back into its slot here
                // would just fight Meta's own maximize. It snaps back into
                // place on unmaximize instead (see append()'s notify hooks).
                if (!window.minimized && !is_driven (window) && !maximized) {
                    window.move_resize_frame (false, target_x, area.y, frame.width, area.height);
                }

                warning ("xy: Row#%d retile monitor=%d title=%s seq=%u x=%d target_x=%d width=%d minimized=%s grabbed=%s driven=%s maximized=%s",
                    id, monitor, window.get_title (), window.get_stable_sequence (), x, target_x, frame.width,
                    window.minimized.to_string (), (window == grabbed_window).to_string (),
                    is_driven (window).to_string (), maximized.to_string ());

                x += frame.width;
            });

            retiling = false;
        }
    }
}
