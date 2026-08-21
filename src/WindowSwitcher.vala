namespace Gala.Plugins.Xy {
    /*
     * Super+Left / Super+Right step focus back and forth through the active
     * workspace's windows, ordered left-to-right by on-screen position and
     * wrapping at the ends.
     *
     * Not most-recently-used order: get_tab_list()'s MRU always has the
     * focused window at index 0, so with discrete key presses (no held grab
     * like Alt+Tab) stepping +1 just ping-pongs between the two most-recent
     * windows. A stable positional order lets both directions walk through
     * every window.
     */
    public class WindowSwitcher : GLib.Object {
        private Gala.WindowManager wm;
        private GLib.Settings settings;

        public WindowSwitcher (Gala.WindowManager wm) {
            this.wm = wm;
            settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");

            var display = wm.get_display ();
            display.add_keybinding ("switch-left", settings, Meta.KeyBindingFlags.NONE, on_switch_left);
            display.add_keybinding ("switch-right", settings, Meta.KeyBindingFlags.NONE, on_switch_right);
        }

        // Named handlers with an explicitly nullable window: the vapi declares
        // the argument non-null, but a lambda would get Vala's auto-inserted
        // null assertion (see the same gotcha in FocusRing).
        private void on_switch_left (Meta.Display display, Meta.Window? window,
                                     Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            switch_focus (display, -1);
        }

        private void on_switch_right (Meta.Display display, Meta.Window? window,
                                      Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            switch_focus (display, 1);
        }

        private void switch_focus (Meta.Display display, int delta) {
            var workspace = display.get_workspace_manager ().get_active_workspace ();

            var windows = new Gee.ArrayList<Meta.Window> ();
            foreach (unowned var window in display.get_tab_list (Meta.TabList.NORMAL, workspace)) {
                if (!FocusRing.is_chrome_window (window)) {
                    windows.add (window);
                }
            }

            if (windows.size < 2) {
                return;
            }

            windows.sort (compare_by_position);

            unowned var focused = display.get_focus_window ();
            int current = -1;
            for (int i = 0; i < windows.size; i++) {
                if (windows[i] == focused) {
                    current = i;
                    break;
                }
            }

            // Nothing (of ours) focused: start from either end so the first
            // press still lands somewhere sensible.
            int next = current < 0
                ? (delta > 0 ? 0 : windows.size - 1)
                : (current + delta + windows.size) % windows.size;

            windows[next].activate (display.get_current_time ());
        }

        // Left-to-right by frame-rect centre, tie-broken top-to-bottom, then
        // by stable sequence so fully-overlapping windows still get a
        // deterministic order (otherwise the cycle could skip or repeat one).
        private static int compare_by_position (Meta.Window a, Meta.Window b) {
            var ra = a.get_frame_rect ();
            var rb = b.get_frame_rect ();

            int ax = ra.x + ra.width / 2;
            int bx = rb.x + rb.width / 2;
            if (ax != bx) {
                return ax - bx;
            }

            int ay = ra.y + ra.height / 2;
            int by = rb.y + rb.height / 2;
            if (ay != by) {
                return ay - by;
            }

            uint sa = a.get_stable_sequence ();
            uint sb = b.get_stable_sequence ();
            return sa < sb ? -1 : (sa > sb ? 1 : 0);
        }

        public void destroy () {
            var display = wm.get_display ();
            display.remove_keybinding ("switch-left");
            display.remove_keybinding ("switch-right");
        }
    }
}
