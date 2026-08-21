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
     */
    public class WindowSwitcher : GLib.Object {
        private Gala.WindowManager wm;
        private GLib.Settings settings;
        private ulong focus_id = 0;

        // Frozen MRU order for the current run of switches, by window
        // get_stable_sequence() (never 0 in Mutter, so 0 is a safe "none").
        private uint[] frozen = {};
        // The window our own last switch activated, so its focus event can be
        // told apart from a real user focus change (which resets `frozen`).
        private uint expecting = 0;

        public WindowSwitcher (Gala.WindowManager wm) {
            this.wm = wm;
            settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");

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
            switch_focus (display, 1);
        }

        private void on_switch_right (Meta.Display display, Meta.Window? window,
                                      Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            switch_focus (display, -1);
        }

        // Any focus change that isn't the one our own switch just triggered
        // means the user moved focus themselves — drop the frozen order so the
        // next switch re-snapshots from current MRU.
        private void on_focus (Meta.Display display, Meta.Window? window, int64 timestamp) {
            if (window != null && window.get_stable_sequence () == expecting) {
                expecting = 0;
                return;
            }

            frozen = {};
            expecting = 0;
        }

        private void switch_focus (Meta.Display display, int delta) {
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
            uint[] order = {};
            foreach (uint seq in frozen) {
                foreach (unowned var window in live) {
                    if (window.get_stable_sequence () == seq) {
                        order += seq;
                        break;
                    }
                }
            }
            if (order.length < 2) {
                order = {};
                foreach (unowned var window in live) {
                    order += window.get_stable_sequence ();
                }
            }
            frozen = order;

            // Re-derive position from the actually-focused window, not a stored
            // index: that's what lets stepping keep advancing through the ring
            // even though each activate() reshuffles Mutter's own MRU underneath.
            unowned var focused = display.get_focus_window ();
            uint focused_seq = focused != null ? focused.get_stable_sequence () : 0;
            int current = 0;
            for (int i = 0; i < frozen.length; i++) {
                if (frozen[i] == focused_seq) {
                    current = i;
                    break;
                }
            }

            uint target_seq = frozen[(current + delta + frozen.length) % frozen.length];
            foreach (unowned var window in live) {
                if (window.get_stable_sequence () == target_seq) {
                    expecting = target_seq;
                    window.activate (display.get_current_time ());
                    return;
                }
            }
        }

        public void destroy () {
            var display = wm.get_display ();
            display.remove_keybinding ("switch-left");
            display.remove_keybinding ("switch-right");

            if (focus_id != 0) {
                display.disconnect (focus_id);
                focus_id = 0;
            }
        }
    }
}
