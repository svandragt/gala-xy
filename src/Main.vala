namespace Gala.Plugins.Xy {
    /*
     * The plugin draws a focus ring around the focused window (FocusRing)
     * and switches focus between windows with Super+Left/Right in MRU order
     * (WindowSwitcher). The old horizontal-tiling layer (rows, retiling,
     * reorder/cycle-width keybindings, drag-to-rehome, divider resize,
     * floating) was removed wholesale — see git history for it if the tiling
     * model gets rethought.
     */
    public class Main : Gala.Plugin {
        private Gala.WindowManager? wm = null;
        private FocusRing focus_ring;
        private WindowSwitcher window_switcher;

        public override void initialize (Gala.WindowManager wm) {
            this.wm = wm;
            focus_ring = new FocusRing (wm);
            window_switcher = new WindowSwitcher (wm);
        }

        public override void destroy () {
            focus_ring.destroy ();
            window_switcher.destroy ();
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
