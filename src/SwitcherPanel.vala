namespace Gala.Plugins.Xy {
    /*
     * The on-screen list shown while Super+Left/Right steps through windows.
     *
     * WindowSwitcher freezes an MRU order for the duration of a run of
     * switches; without any feedback there's no way to tell how many more
     * presses reach a given window. This panel renders that frozen order as a
     * vertical list of window titles with the just-focused one highlighted, so
     * the rows above/below the highlight are literally the number of presses
     * away. It fades in on the first press, re-arms its hide timer on every
     * subsequent one, and disappears once the user stops (or focus moves for
     * real, which drops the frozen order anyway).
     *
     * Everything is painted in one Cairo pass on a Gala.CanvasActor, the same
     * drawing path FocusRing uses — composing Clutter.Text children would mean
     * relying on rather more of the Mutter 46 vapi than this repo has proven.
     */
    internal class SwitcherPanelContent : Gala.CanvasActor {
        public const int ROW_HEIGHT = 32;
        public const int PADDING = 12;
        public const int TEXT_PADDING = 10;
        private const int RADIUS = 8;
        private const int ROW_RADIUS = 4;

        // Same fallback accent as FocusRing's, replaced with the real one from
        // Granite.Settings as soon as SwitcherPanel constructs this.
        private Clutter.Color accent = { 0x64, 0xba, 0xff, 0xff };
        private string[] titles = {};
        private int highlighted = -1;

        public void set_accent (Gdk.RGBA rgba) {
            accent = {
                (uint8) Math.round (rgba.red * 255),
                (uint8) Math.round (rgba.green * 255),
                (uint8) Math.round (rgba.blue * 255),
                (uint8) Math.round (rgba.alpha * 255),
            };

            // See FocusRingContent.set_color: CanvasActor caches its Cogl
            // texture, so a repaint that isn't preceded by a resize needs an
            // explicit invalidate () or draw () never re-runs.
            content.invalidate ();
        }

        public void set_items (string[] titles, int highlighted) {
            this.titles = titles;
            this.highlighted = highlighted;
            content.invalidate ();
        }

        // The desktop-wide default font, so the list matches every other bit
        // of Pantheon chrome. Read once: org.gnome.desktop.interface is a base
        // dependency on elementary, so the key is always present.
        private static string? font_name = null;

        // A layout configured exactly like the one draw () renders with, so
        // SwitcherPanel can measure the widest title before sizing the actor.
        public static Pango.Layout create_layout (Cairo.Context cr) {
            if (font_name == null) {
                font_name = new GLib.Settings ("org.gnome.desktop.interface").get_string ("font-name");
                if (font_name == "") {
                    font_name = "Sans 10";
                }
            }

            var layout = Pango.cairo_create_layout (cr);
            layout.set_font_description (Pango.FontDescription.from_string (font_name));
            return layout;
        }

        protected override void draw (Cairo.Context cr, int width, int height) {
            cr.set_operator (Cairo.Operator.CLEAR);
            cr.paint ();
            cr.set_operator (Cairo.Operator.OVER);

            cr.set_source_rgba (0.0, 0.0, 0.0, 0.8);
            Gala.Drawing.Utilities.cairo_rounded_rectangle (cr, 0, 0, width, height, RADIUS);
            cr.fill ();

            var layout = create_layout (cr);
            layout.set_ellipsize (Pango.EllipsizeMode.END);
            layout.set_width ((width - 2 * PADDING - 2 * TEXT_PADDING) * Pango.SCALE);

            for (int i = 0; i < titles.length; i++) {
                double row_y = PADDING + i * ROW_HEIGHT;

                if (i == highlighted) {
                    cr.set_source_rgba (accent.red / 255.0, accent.green / 255.0,
                        accent.blue / 255.0, accent.alpha / 255.0);
                    Gala.Drawing.Utilities.cairo_rounded_rectangle (cr,
                        PADDING, row_y, width - 2 * PADDING, ROW_HEIGHT, ROW_RADIUS);
                    cr.fill ();
                }

                layout.set_text (titles[i], -1);
                int text_width, text_height;
                layout.get_pixel_size (out text_width, out text_height);

                cr.set_source_rgba (1.0, 1.0, 1.0, 1.0);
                cr.move_to (PADDING + TEXT_PADDING, row_y + (ROW_HEIGHT - text_height) / 2.0);
                Pango.cairo_show_layout (cr, layout);
            }
        }
    }

    public class SwitcherPanel : GLib.Object {
        private const int MIN_WIDTH = 240;
        private const int MAX_WIDTH = 480;
        private const uint FADE_IN_DURATION = 100;
        private const uint FADE_OUT_DURATION = 150;
        // How often to check whether the switch modifier is still held. Fast
        // enough that the hide feels tied to the key release, cheap enough to
        // ignore.
        private const uint POLL_INTERVAL = 80;

        private Gala.WindowManager wm;
        private GLib.Settings settings;
        private SwitcherPanelContent panel;
        private ulong accent_color_id = 0;
        private uint poll_id = 0;
        private uint hidden_id = 0;
        // The accelerator's held modifier (Super) and, once it's released, the
        // monotonic-clock deadline to hide at. -1 means "still held, no
        // countdown running".
        private uint modifier_mask = 0;
        private int64 release_deadline = -1;

        public SwitcherPanel (Gala.WindowManager wm) {
            this.wm = wm;
            settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");

            panel = new SwitcherPanelContent ();
            panel.visible = false;
            panel.opacity = 0;
            wm.ui_group.add_child (panel);

            var granite_settings = Granite.Settings.get_default ();
            panel.set_accent (granite_settings.accent_color);
            accent_color_id = granite_settings.notify["accent-color"].connect (() => {
                panel.set_accent (granite_settings.accent_color);
            });
        }

        public void show_for (Gee.List<unowned Meta.Window> windows, int highlighted, uint modifier_mask) {
            if (!settings.get_boolean ("switcher-panel") || windows.size == 0) {
                return;
            }

            this.modifier_mask = modifier_mask;

            string[] titles = {};
            foreach (unowned var window in windows) {
                string? title = window.get_title ();
                titles += title != null ? title : "";
            }

            int width, height;
            measure (titles, out width, out height);

            panel.set_items (titles, highlighted);
            panel.set_size (width, height);
            position (width, height);

            // ui_group holds the focus ring too (until it reparents itself next
            // to the focused window's actor), so make sure the panel is on top
            // of whatever else this group is currently holding.
            wm.ui_group.set_child_above_sibling (panel, null);

            if (hidden_id != 0) {
                GLib.Source.remove (hidden_id);
                hidden_id = 0;
            }

            panel.visible = true;
            panel.save_easing_state ();
            panel.set_easing_duration (FADE_IN_DURATION);
            panel.opacity = 255;
            panel.restore_easing_state ();

            // Restart the countdown: keep the panel up until the modifier is
            // released, then hide switcher-panel-timeout ms later. Re-arming on
            // every press means holding Super and tapping the arrows keeps it
            // alive; the poll only starts counting down once Super lets go.
            release_deadline = -1;
            if (poll_id == 0) {
                poll_id = GLib.Timeout.add (POLL_INTERVAL, poll_release);
            }
        }

        // While the modifier is held, keep resetting the countdown. Once it's
        // released, arm the deadline; when that passes, hide. A no-modifier
        // accelerator (mask 0) can't be "held", so it counts down immediately —
        // degrading to the old fixed dwell after the last press.
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
                hide ();
                return GLib.Source.REMOVE;
            }

            return GLib.Source.CONTINUE;
        }

        private Clutter.ModifierType current_modifiers () {
            Clutter.ModifierType mods;
            wm.get_display ().get_cursor_tracker ().get_pointer (null, out mods);
            return mods & Clutter.ModifierType.MODIFIER_MASK;
        }

        public void hide () {
            if (poll_id != 0) {
                GLib.Source.remove (poll_id);
                poll_id = 0;
            }

            if (!panel.visible || hidden_id != 0) {
                return;
            }

            panel.save_easing_state ();
            panel.set_easing_duration (FADE_OUT_DURATION);
            panel.opacity = 0;
            panel.restore_easing_state ();

            // Hide only once the fade has actually run; a timeout rather than a
            // transitions_completed handler so there's exactly one source id to
            // cancel if a new switch comes in mid-fade.
            hidden_id = GLib.Timeout.add (FADE_OUT_DURATION, () => {
                hidden_id = 0;
                panel.visible = false;
                return GLib.Source.REMOVE;
            });
        }

        // Widest title (capped) decides the width; one row per window decides
        // the height. Measured against a throwaway 1x1 surface with the same
        // layout settings draw () uses, so the text can't come out wider than
        // what was reserved for it.
        private void measure (string[] titles, out int width, out int height) {
            int text_width = 0;

            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, 1, 1);
            var cr = new Cairo.Context (surface);
            var layout = SwitcherPanelContent.create_layout (cr);
            foreach (unowned string title in titles) {
                layout.set_text (title, -1);
                int w, h;
                layout.get_pixel_size (out w, out h);
                if (w > text_width) {
                    text_width = w;
                }
            }

            width = text_width + 2 * SwitcherPanelContent.PADDING + 2 * SwitcherPanelContent.TEXT_PADDING;
            width = int.max (MIN_WIDTH, int.min (MAX_WIDTH, width));
            height = titles.length * SwitcherPanelContent.ROW_HEIGHT + 2 * SwitcherPanelContent.PADDING;
        }

        // Always centred on the primary monitor: switching focus moves the
        // focused window's monitor around, and the panel jumping to follow it
        // is disorienting, so it stays put where the user is looking.
        private void position (int width, int height) {
            var display = wm.get_display ();
            var geometry = display.get_monitor_geometry (display.get_primary_monitor ());
            panel.set_position (
                geometry.x + (geometry.width - width) / 2,
                geometry.y + (geometry.height - height) / 2
            );
        }

        public void destroy () {
            if (poll_id != 0) {
                GLib.Source.remove (poll_id);
                poll_id = 0;
            }

            if (hidden_id != 0) {
                GLib.Source.remove (hidden_id);
                hidden_id = 0;
            }

            if (accent_color_id != 0) {
                Granite.Settings.get_default ().disconnect (accent_color_id);
                accent_color_id = 0;
            }

            panel.destroy ();
        }
    }
}
