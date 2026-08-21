namespace Xy {
    // Switchboard entry point for gala-xy's settings. Reads/writes the
    // same schema the plugin itself uses (org.pantheon.desktop.gala.plugins.
    // xy) — this is just a GUI over the same gsettings keys documented
    // in the plugin's README, nothing plugin-specific lives here.
    public class SettingsPlug : Switchboard.Plug {
        private Gtk.Widget? main_widget = null;

        public SettingsPlug () {
            var settings = new Gee.TreeMap<string, string?> ();
            settings.set ("xy", "Window Behaviour");

            Object (
                category: Switchboard.Plug.Category.PERSONAL,
                code_name: "io.elementary.settings.xy",
                display_name: "Window Behaviour",
                description: "Window switching shortcuts and focus-ring exclusions",
                icon: "preferences-desktop-workspaces",
                supported_settings: settings
            );
        }

        public override Gtk.Widget get_widget () {
            if (main_widget == null) {
                main_widget = new SettingsView ().build ();
            }

            return main_widget;
        }

        public override void shown () {}

        public override void hidden () {}

        // No in-plug search targets (just two settings groups, both always
        // visible) — nothing meaningful to jump to beyond opening the plug.
        public override async Gee.TreeMap<string, string> search (string search) {
            return new Gee.TreeMap<string, string> ();
        }

        public override void search_callback (string location) {}
    }
}

public Switchboard.Plug get_plug (GLib.Module module) {
    debug ("Activating Xy settings plug");
    return new Xy.SettingsPlug ();
}
