namespace Gala.Plugins.Xy {
    /*
     * Currently the plugin does nothing but draw a focus ring around the
     * focused window. The horizontal-tiling layer (rows, retiling, reorder/
     * focus-neighbor/cycle-width keybindings, drag-to-rehome, divider
     * resize, floating) was removed wholesale — see git history for it if
     * the tiling model gets rethought.
     */
    public class Main : Gala.Plugin {
        private Gala.WindowManager? wm = null;
        private FocusRing focus_ring;

        public override void initialize (Gala.WindowManager wm) {
            this.wm = wm;
            focus_ring = new FocusRing (wm);
        }

        public override void destroy () {
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
