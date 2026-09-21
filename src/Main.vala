namespace Gala.Plugins.Xy {
    /*
     * The plugin draws a focus ring around the focused window (FocusRing)
     * and switches focus between windows with Super+Left/Right in MRU order
     * (WindowSwitcher). The old horizontal-tiling layer (rows, retiling,
     * reorder/cycle-width keybindings, drag-to-rehome, divider resize,
     * floating) was removed wholesale — see git history for it if the tiling
     * model gets rethought. The `enabled` key is a runtime kill switch,
     * toggled by its own keybinding, that tears both down (and releases the
     * switch shortcuts back to Gala) without needing to log out.
     */
    public class Main : Gala.Plugin {
        private Gala.WindowManager? wm = null;
        private GLib.Settings settings;
        private FocusRing? focus_ring = null;
        private WindowSwitcher? window_switcher = null;

        public override void initialize (Gala.WindowManager wm) {
            this.wm = wm;
            settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");

            var display = wm.get_display ();
            display.add_keybinding ("toggle-enabled", settings, Meta.KeyBindingFlags.NONE, on_toggle_enabled);
            settings.changed["enabled"].connect (apply_enabled);

            apply_enabled ();
        }

        // Named handler with an explicitly nullable window — see the same
        // gotcha called out in WindowSwitcher: a lambda would get Vala's
        // auto-inserted null assertion and crash Gala when focus is cleared.
        private void on_toggle_enabled (Meta.Display display, Meta.Window? window,
                                        Clutter.KeyEvent? event, Meta.KeyBinding binding) {
            settings.set_boolean ("enabled", !settings.get_boolean ("enabled"));
        }

        // Brings the plugin up or tears it down to match the `enabled` key.
        // Idempotent both ways, so it's safe to call from initialize() and
        // from the settings-changed handler alike.
        private void apply_enabled () {
            if (settings.get_boolean ("enabled")) {
                if (focus_ring == null) {
                    focus_ring = new FocusRing (wm);
                    window_switcher = new WindowSwitcher (wm);

                    // Unlike Gala's own startup, re-enabling here has no
                    // focus change pending to trigger FocusRing's first
                    // track on its own — seed it explicitly. Deferred via
                    // GLib.Idle.add() for the same actor-realization
                    // timing FocusRing's constructor comment describes;
                    // null-checked because the user could toggle back off
                    // again before this runs.
                    GLib.Idle.add (() => {
                        if (focus_ring != null) {
                            focus_ring.track_focused ();
                        }

                        return GLib.Source.REMOVE;
                    });
                }
            } else if (focus_ring != null) {
                focus_ring.destroy ();
                window_switcher.destroy ();
                focus_ring = null;
                window_switcher = null;
            }
        }

        public override void destroy () {
            var display = wm.get_display ();
            display.remove_keybinding ("toggle-enabled");

            if (focus_ring != null) {
                focus_ring.destroy ();
            }
            if (window_switcher != null) {
                window_switcher.destroy ();
            }
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
