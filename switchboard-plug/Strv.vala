namespace Xy {
    // The GSettings `as` (string array) <-> single comma-separated
    // Gtk.Entry mapping used by add_strv_row(). Kept out of SettingsView.vala
    // so the test binary links GLib alone, not gtk4 + switchboard-3 +
    // granite (see tests/logic-test.vala).
    public class Strv {
        // GSettings' vapi only exposes the plain-C-function-pointer form of
        // these mappings (has_target = false), so they're static methods
        // with an unused user_data, not closures.
        public static bool to_text (GLib.Value value, GLib.Variant variant, void* user_data) {
            value.set_string (string.joinv (", ", variant.get_strv ()));
            return true;
        }

        public static GLib.Variant to_strv (GLib.Value value, GLib.VariantType expected_type, void* user_data) {
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
