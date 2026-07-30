namespace Xy {
    // A sidebar + stack, like every other multi-section Switchboard plug
    // (confirmed by inspecting io.elementary.settings.mouse-touchpad's
    // actual widget tree live: GtkPaned > [SettingsSidebar, GtkStack]) —
    // returning a plain Gtk.Box here instead left the shell with nothing to
    // put in its sidebar and no page-navigation chrome (no back button),
    // since both come from Switchboard.SettingsSidebar being bound to the
    // same Gtk.Stack the content lives in, not something the shell adds on
    // its own.
    //
    // Not a Gtk.Paned *subclass*: the same live inspection showed the real
    // plug's top widget type name is the literal "GtkPaned", not a custom
    // subclass — GTK4 keeps most widget instance structs opaque, so
    // `class Foo : Gtk.Paned` fails to compile ("field 'parent_instance'
    // has incomplete type"). Building a plain Gtk.Paned via composition,
    // like the real plug does, is the only option.
    public class SettingsView : GLib.Object {
        public Gtk.Widget build () {
            var settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");

            var stack = new Gtk.Stack ();
            stack.add_titled (new ExclusionsPage (settings), "exclusions", "Exclusions");

            // show_title_buttons reveals SettingsSidebar's own header bar,
            // which is what the shell's Adw.NavigationView back button rides
            // on once this plug is pushed as a non-root Adw.NavigationPage —
            // without it the header (and the back chrome) never appears,
            // confirmed against elementary/settings-desktop's Plug.vala,
            // which sets this explicitly on every multi-page plug.
            var sidebar = new Switchboard.SettingsSidebar (stack) {
                show_title_buttons = true
            };

            return new Gtk.Paned (Gtk.Orientation.HORIZONTAL) {
                start_child = sidebar,
                end_child = stack,
                resize_start_child = false,
                shrink_start_child = false
            };
        }
    }

    // Same keys FocusRing.is_chrome_window() reads at runtime (see gala-xy's
    // gschema) — a window matching either list is treated as system chrome
    // and never gets a focus ring.
    //
    // SwitchboardSettingsSidebar reads title/header/status straight off each
    // stack page's child widget by casting it to Switchboard.SettingsPage
    // (confirmed by GLib-GObject-CRITICAL "invalid object type ... for value
    // type 'SwitchboardSettingsPage'" when a plain Gtk.Grid/Gtk.Box was used
    // instead) — a plain content widget isn't enough, the page must actually
    // be one.
    private class ExclusionsPage : Switchboard.SettingsPage {
        private GLib.Settings settings;

        public ExclusionsPage (GLib.Settings settings) {
            Object (title: "Exclusions", header: "Excluded Windows");
            this.settings = settings;

            var description = new Gtk.Label (
                "Windows matching any of these are treated as system chrome and never get a focus ring."
            ) {
                wrap = true,
                xalign = 0,
                margin_bottom = 12
            };
            description.add_css_class ("dim-label");

            var grid = new Gtk.Grid () {
                row_spacing = 12,
                column_spacing = 12
            };

            add_strv_row (grid, 0, "Title contains", "excluded-title-keywords", "wingpanel, plank");
            add_strv_row (grid, 1, "Application ID is", "excluded-app-ids", "com.example.app");

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                margin_top = 24,
                margin_bottom = 24,
                margin_start = 24,
                margin_end = 24
            };
            box.append (description);
            box.append (grid);
            child = box;
        }

        // Each key is a gschema `as`, shown as one comma-separated entry.
        private void add_strv_row (Gtk.Grid grid, int row, string label_text, string key, string? placeholder) {
            var label = new Gtk.Label (label_text) {
                xalign = 1,
                hexpand = false
            };
            label.add_css_class ("dim-label");

            var entry = new Gtk.Entry () {
                hexpand = true
            };
            if (placeholder != null) {
                entry.placeholder_text = placeholder;
            }

            settings.bind_with_mapping (
                key, entry, "text", GLib.SettingsBindFlags.DEFAULT,
                strv_to_text, text_to_strv, null, null
            );

            grid.attach (label, 0, row, 1, 1);
            grid.attach (entry, 1, row, 1, 1);
        }

        // GSettings' vapi only exposes the plain-C-function-pointer form of
        // these mappings (has_target = false), so they're static methods
        // with an unused user_data, not closures.
        private static bool strv_to_text (GLib.Value value, GLib.Variant variant, void* user_data) {
            value.set_string (string.joinv (", ", variant.get_strv ()));
            return true;
        }

        private static GLib.Variant text_to_strv (GLib.Value value, GLib.VariantType expected_type, void* user_data) {
            string text = value.get_string ();
            string[] items = {};
            foreach (unowned string part in text.split (",")) {
                string trimmed = part.strip ();
                if (trimmed != "") {
                    items += trimmed;
                }
            }

            return new GLib.Variant.strv (items);
        }
    }
}
