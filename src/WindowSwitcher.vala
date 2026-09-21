namespace Gala.Plugins.Xy {
    /*
     * Super+Left / Super+Right step focus through the active workspace's
     * windows in most-recently-used order, wrapping at the ends — like
     * Alt+Tab, but on discrete key presses.
     *
     * The catch with MRU: every activate() promotes its window to the front
     * of Mutter's tab list, so reading get_tab_list() live on each press
     * would just ping-pong between the two most-recent windows. So the MRU
     * order is snapshotted once (as stable-sequence ids, which stay valid
     * even as windows close) and held frozen while stepping; the current
     * position is re-derived from the actually-focused window each press, so
     * both directions walk the whole ring. The snapshot is dropped as soon as
     * a *real* focus change happens (a click, a new window) — anything that
     * isn't one of our own switches — so the next press starts from fresh MRU.
     *
     * Each step still calls activate() on its target, same as a plain
     * Alt+Tab-less switch would — the window the user steps onto comes
     * forward immediately. What's new is what happens to the window they
     * step *away* from: it should drop back to wherever it was stacked
     * before the run started, not linger on top. There's no
     * set-stack-position call in the vapi, so the only way to *restore* a
     * stacking order is to *replay* it — raise() everything, bottom to top,
     * in the order it was in before. So the stacking order (not the MRU
     * order above — a separate snapshot) is captured once, on the first
     * press of a run, and replayed by raise()ing every window in it,
     * bottom-to-top, immediately before each press's activate(). That
     * replay deliberately uses raise() and not activate() or
     * raise_and_make_recent(): raise() restacks without promoting a window
     * in Mutter's tab list, so replaying it doesn't disturb the frozen MRU
     * order this switcher is stepping through above.
     *
     * Each switch also hands that frozen order to SwitcherPanel, which shows
     * it on screen with the newly-focused window highlighted, so the user can
     * see how many more presses reach the window they're after.
     */
    public class WindowSwitcher : GLib.Object {
        private Gala.WindowManager wm;
        private GLib.Settings settings;
        private SwitcherPanel panel;
        private ulong focus_id = 0;

        // Frozen MRU order for the current run of switches, by window
        // get_stable_sequence() (never 0 in Mutter, so 0 is a safe "none").
        private uint[] frozen = {};
        // The window our own last switch activated, so its focus event can be
        // told apart from a real user focus change (which resets `frozen`).
        private uint expecting = 0;
        // The monitor the panel sits on for the current run, latched from the
        // window focused when the run began (where the user's eyes are) and
        // held so the panel doesn't hop displays as focus moves across them.
        // -1 means no run in progress. Reset together with `frozen`.
        private int run_monitor = -1;
        // The stacking order at the start of the current run, bottom to top,
        // by stable sequence — what restore_stack() replays before each
        // press's activate(). Reset together with `frozen`.
        private uint[] original_stack = {};
        private uint poll_id = 0;
        // The accelerator's held modifier (Super) and, once it's released, the
        // monotonic-clock deadline to hide at. -1 means "still held, no
        // countdown running".
        private uint modifier_mask = 0;
        private int64 release_deadline = -1;
        // How often to check whether the switch modifier is still held. Fast
        // enough that the commit feels tied to the key release, cheap enough
        // to ignore.
        private const uint POLL_INTERVAL = 80;

        public WindowSwitcher (Gala.WindowManager wm) {
            this.wm = wm;
            settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");
            panel = new SwitcherPanel (wm);

            var display = wm.get_display ();
            display.add_keybinding ("switch-left", settings, Meta.KeyBindingFlags.NONE, on_switch_left);
            display.add_keybinding ("switch-right", settings, Meta.KeyBindingFlags.NONE, on_switch_right);
            focus_id = display.do_focus_window.connect (on_focus);
        }

        // Named handlers with an explicitly nullable window: the vapi declares
        // the argument non-null, but a lambda would get Vala's auto-inserted
        // null assertion (see the same gotcha in FocusRing).
        //
        // Left is Back and Right is Forward, like a browser: Left steps toward
        // older entries in the recently-used order (+1 down the frozen list,
        // so the first press lands on the previously-focused window), Right
        // steps back toward the most-recent.
        private void on_switch_left (Meta.Display display, Meta.Window? window,
                                     Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            switch_focus (display, 1, primary_modifier (binding.get_mask ()));
        }

        private void on_switch_right (Meta.Display display, Meta.Window? window,
                                      Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            switch_focus (display, -1, primary_modifier (binding.get_mask ()));
        }

        // The single held-down modifier of the accelerator (Super, for the
        // Super+arrow defaults): the highest set bit of its mask, isolated the
        // way gnome-shell and Gala's own switcher do. The panel watches this
        // key so it can stay up until the user lets go of it.
        private static uint primary_modifier (uint mask) {
            if (mask == 0) {
                return 0;
            }

            uint primary = 1;
            while (mask > 1) {
                mask >>= 1;
                primary <<= 1;
            }
            return primary;
        }

        private Clutter.ModifierType current_modifiers () {
            Clutter.ModifierType mods;
            wm.get_display ().get_cursor_tracker ().get_pointer (null, out mods);
            return mods & Clutter.ModifierType.MODIFIER_MASK;
        }

        // Any focus change that isn't the one our own switch just triggered
        // means the user moved focus themselves — drop the frozen order so the
        // next switch re-snapshots from current MRU, and take the panel down
        // with it, since it was showing an order that no longer applies.
        private void on_focus (Meta.Display display, Meta.Window? window, int64 timestamp) {
            if (window != null && window.get_stable_sequence () == expecting) {
                expecting = 0;
                return;
            }

            frozen = {};
            expecting = 0;
            run_monitor = -1;
            original_stack = {};
            if (poll_id != 0) {
                GLib.Source.remove (poll_id);
                poll_id = 0;
            }
            panel.hide ();
        }

        private void switch_focus (Meta.Display display, int delta, uint modifier_mask) {
            var workspace = display.get_workspace_manager ().get_active_workspace ();

            // Live windows in Mutter's current MRU order, chrome excluded.
            var live = new Gee.ArrayList<unowned Meta.Window> ();
            foreach (unowned var window in display.get_tab_list (Meta.TabList.NORMAL, workspace)) {
                if (!FocusRing.is_chrome_window (window)) {
                    live.add (window);
                }
            }

            if (live.size < 2) {
                return;
            }

            // Keep the frozen order but drop any window that has since closed;
            // reseed from live MRU when there's no usable snapshot left.
            var ordered = new Gee.ArrayList<unowned Meta.Window> ();
            foreach (uint seq in frozen) {
                foreach (unowned var window in live) {
                    if (window.get_stable_sequence () == seq) {
                        ordered.add (window);
                        break;
                    }
                }
            }
            if (ordered.size < 2) {
                ordered.clear ();
                ordered.add_all (live);
            }

            frozen = {};
            foreach (unowned var window in ordered) {
                frozen += window.get_stable_sequence ();
            }

            // Re-derive position from the actually-focused window, not a stored
            // index: that's what lets stepping keep advancing through the ring
            // even though each activate() reshuffles Mutter's own MRU underneath.
            unowned var focused = display.get_focus_window ();
            uint focused_seq = focused != null ? focused.get_stable_sequence () : 0;

            // First press of a run: snapshot the current stacking order for
            // restore_stack() to replay later, and latch the panel to the
            // monitor of the window focused right now, before we activate
            // the target — that's still where the user was looking. Both
            // only make sense once per run, hence sharing this guard.
            if (run_monitor < 0) {
                var to_sort = new GLib.SList<Meta.Window> ();
                foreach (unowned var window in display.get_tab_list (Meta.TabList.NORMAL, workspace)) {
                    to_sort.append (window);
                }

                // Sorted lowest to highest per meta_display_sort_windows_by_stacking()'s
                // own doc comment — matches the bottom-to-top order `original_stack`
                // is stored in and restore_stack() replays.
                original_stack = {};
                foreach (unowned var window in display.sort_windows_by_stacking (to_sort)) {
                    original_stack += window.get_stable_sequence ();
                }

                if (focused != null) {
                    run_monitor = focused.get_monitor ();
                }
            }
            int current = 0;
            for (int i = 0; i < frozen.length; i++) {
                if (frozen[i] == focused_seq) {
                    current = i;
                    break;
                }
            }

            int target = (current + delta + ordered.size) % ordered.size;
            unowned var target_window = ordered[target];

            expecting = target_window.get_stable_sequence ();

            // Drop whatever the previous step raised back to its pre-run
            // position before raising the new target — see restore_stack().
            restore_stack ();
            target_window.activate (display.get_current_time ());

            this.modifier_mask = modifier_mask;
            panel.show_for (ordered, target, run_monitor);

            // Keep polling for the modifier release across the whole run:
            // re-arming here (rather than only starting it once) would let a
            // held Super key's countdown restart on every press even though
            // it's still down, which the `< 0` check below already handles.
            release_deadline = -1;
            if (poll_id == 0) {
                poll_id = GLib.Timeout.add (POLL_INTERVAL, poll_release);
            }
        }

        // Nothing left to commit — activate() already happened on the press
        // itself. This poll now exists purely to time the panel's fade-out:
        // while the modifier is held, keep resetting the countdown; once
        // it's released, arm the deadline; once that deadline passes, hide
        // the panel and stop polling.
        private bool poll_release () {
            if (modifier_mask != 0 && (current_modifiers () & modifier_mask) != 0) {
                release_deadline = -1;
                return GLib.Source.CONTINUE;
            }

            int64 now = GLib.get_monotonic_time ();
            if (release_deadline < 0) {
                release_deadline = now + (int64) settings.get_int ("switcher-panel-timeout") * 1000;
                return GLib.Source.CONTINUE;
            }

            if (now >= release_deadline) {
                poll_id = 0;
                panel.hide ();
                return GLib.Source.REMOVE;
            }

            return GLib.Source.CONTINUE;
        }

        // Restores whatever raise() order was in effect before this run
        // started, by replaying original_stack bottom to top — raise() puts
        // each window immediately above the previous one, so replaying the
        // whole snapshot in order reproduces it exactly. Uses raise(), never
        // activate()/raise_and_make_recent(): those would re-promote every
        // window in the snapshot to the front of Mutter's tab list, wiping
        // out the frozen MRU order above.
        //
        // ponytail: O(N) raise() calls per keypress for N windows on the
        // workspace. Mutter coalesces restacks into a single compositor
        // frame, so this isn't expected to flicker; upgrade path is a real
        // stack-position API, if Mutter ever exposes one.
        private void restore_stack () {
            if (original_stack.length == 0) {
                return;
            }

            var display = wm.get_display ();
            var workspace = display.get_workspace_manager ().get_active_workspace ();
            var live = display.get_tab_list (Meta.TabList.NORMAL, workspace);

            foreach (uint seq in original_stack) {
                foreach (unowned var window in live) {
                    if (window.get_stable_sequence () == seq) {
                        window.raise ();
                        break;
                    }
                }
            }
        }

        public void destroy () {
            if (poll_id != 0) {
                GLib.Source.remove (poll_id);
                poll_id = 0;
            }

            var display = wm.get_display ();
            display.remove_keybinding ("switch-left");
            display.remove_keybinding ("switch-right");

            if (focus_id != 0) {
                display.disconnect (focus_id);
                focus_id = 0;
            }

            panel.destroy ();
        }
    }
}
