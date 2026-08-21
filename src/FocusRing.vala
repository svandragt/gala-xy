namespace Gala.Plugins.Xy {
    /*
     * Draws the focused window's border as a rounded-rect stroke via
     * Gala.CanvasActor (Gala's own Cairo-backed canvas actor — not
     * Clutter.Canvas, which the vapi excludes as of Mutter 46, the version
     * this plugin targets). The stroke is drawn inset within the tracked
     * window's own frame rect rather than offset outside it: a window's
     * frame rect is always within the stage's own bounds, so an inset ring
     * can never get clipped off the edge of the screen the way an outset
     * one did when a window was full-width or full-height on its monitor.
     */
    internal class FocusRingContent : Gala.CanvasActor {
        public const int THICKNESS = 3;
        // elementary's own per-window corner radius is drawn client-side by
        // each app's CSD theme and isn't queryable from a plugin; this is an
        // approximation matching the common Granite/GTK default, not a
        // per-window-accurate value.
        private const int RADIUS = 6;
        // Fallback used only until FocusRing has a chance to apply the real
        // accent color from Granite.Settings (or if Granite ever reports
        // none). Kept as the pre-existing blue so there's never a moment
        // with no color set at all.
        private Clutter.Color color = { 0x64, 0xba, 0xff, 0xff };

        public void set_color (Gdk.RGBA rgba) {
            color = {
                (uint8) Math.round (rgba.red * 255),
                (uint8) Math.round (rgba.green * 255),
                (uint8) Math.round (rgba.blue * 255),
                (uint8) Math.round (rgba.alpha * 255),
            };

            // CanvasActor's content is a cached Cogl texture (see Gala's
            // Drawing.Canvas): queue_redraw() alone just repaints that
            // existing texture, it doesn't re-run draw() to regenerate it.
            // Only Clutter.Content.invalidate() does — set_size() gets this
            // for free on the next resize, but a color change with no size
            // change needs it forced here or the ring keeps showing the old
            // color until something else happens to resize/reallocate it.
            content.invalidate ();
        }

        protected override void draw (Cairo.Context cr, int width, int height) {
            cr.set_operator (Cairo.Operator.CLEAR);
            cr.paint ();
            cr.set_operator (Cairo.Operator.OVER);

            cr.set_source_rgba (color.red / 255.0, color.green / 255.0, color.blue / 255.0, color.alpha / 255.0);
            cr.set_line_width (THICKNESS);
            Gala.Drawing.Utilities.cairo_rounded_rectangle (cr,
                THICKNESS / 2.0, THICKNESS / 2.0,
                width - THICKNESS, height - THICKNESS,
                RADIUS);
            cr.stroke ();
        }
    }

    public class FocusRing : GLib.Object {
        // System chrome (wingpanel/plank by title, Sidewing by GTK app ID)
        // shouldn't pick up a focus-ring border. Both lists come from
        // gsettings so excluding another panel/dock doesn't need a rebuild:
        // `gsettings set org.pantheon.desktop.gala.plugins.xy
        // excluded-app-ids "['some.app.id']"`. Sidewing is matched by app ID
        // rather than title because only one of its windows has "sidewing"
        // in the title.
        private static GLib.Settings? exclusion_settings = null;

        private static bool is_chrome_window (Meta.Window window) {
            if (exclusion_settings == null) {
                exclusion_settings = new GLib.Settings ("org.pantheon.desktop.gala.plugins.xy");
            }

            string title = window.get_title ().down ();
            foreach (unowned string keyword in exclusion_settings.get_strv ("excluded-title-keywords")) {
                if (keyword != "" && title.contains (keyword.down ())) {
                    return true;
                }
            }

            string? app_id = window.get_gtk_application_id ();
            if (app_id != null) {
                foreach (unowned string excluded_id in exclusion_settings.get_strv ("excluded-app-ids")) {
                    if (app_id == excluded_id) {
                        return true;
                    }
                }
            }

            return false;
        }

        private Gala.WindowManager wm;
        private FocusRingContent ring;

        private ulong accent_color_id = 0;
        private ulong do_focus_window_id = 0;
        private ulong restacked_id = 0;

        private unowned Meta.Window? tracked = null;
        private ulong position_signal = 0;
        private ulong size_signal = 0;
        // Guards against dereferencing `tracked` after it's destroyed: if
        // focus doesn't get reassigned before the tracked window is fully
        // gone, do_focus_window() may not fire in time, leaving `tracked`
        // dangling until the next focus change tries to disconnect its
        // (now invalid) signal ids. Untracking directly on unmanaged avoids
        // relying on that ordering.
        private ulong unmanaged_signal = 0;

        public FocusRing (Gala.WindowManager wm) {
            this.wm = wm;

            ring = new FocusRingContent ();
            ring.visible = false;

            wm.ui_group.add_child (ring);

            // Track System Settings > Appearance's accent color live: Granite
            // already surfaces it as a plain GObject property (backed by
            // AccountsService under the hood), so a notify handler is all
            // that's needed to pick up a change the moment the user makes it
            // — no polling or gsettings-key wiring of our own.
            var granite_settings = Granite.Settings.get_default ();
            ring.set_color (granite_settings.accent_color);
            accent_color_id = granite_settings.notify["accent-color"].connect (() => {
                ring.set_color (granite_settings.accent_color);
            });

            var display = wm.get_display ();
            do_focus_window_id = display.do_focus_window.connect (on_focus_window);
            // An always-on-top window (make_above ()) stays visually in front
            // of the focused window regardless of focus, but the ring lives
            // in ui_group above every window layer, so without this it drew
            // over such windows even when they were stacked above the focus.
            // restacked fires whenever above-ness or stacking order changes,
            // so re-check visibility then, not just on move/resize.
            restacked_id = display.restacked.connect (() => update ());

            // Deliberately not calling track() eagerly here with whatever
            // window already has focus: `ring` was just add_child()'d this
            // same tick, and calling its position/size setters before
            // Clutter considers the actor realized logged a reproducible
            // `clutter_actor_get_width/height: assertion 'CLUTTER_IS_ACTOR
            // (self)' failed` on every single Gala start — and deferring
            // via a single GLib.Idle.add() wasn't a long enough wait to
            // fix it either. Mutter/Gala always assigns (or explicitly
            // clears) focus once during its own startup, so do_focus_window
            // fires on its own moments later regardless — by then `ring`
            // has had a full frame cycle to become valid, and the ring
            // simply appears a beat later than at eager-track, which
            // isn't perceptible.
        }

        // Named handler with an explicitly nullable window: the vapi
        // declares this signal's window argument as non-null, so a lambda
        // here would get Vala's auto-inserted `window != NULL` assertion
        // and crash whenever focus is cleared (e.g. right at Gala startup).
        private void on_focus_window (Meta.Display display, Meta.Window? window, int64 timestamp) {
            track (window);
        }

        private void track (Meta.Window? window) {
            if (tracked != null) {
                tracked.disconnect (position_signal);
                tracked.disconnect (size_signal);
                tracked.disconnect (unmanaged_signal);
                tracked = null;
            }

            if (window == null || !Utils.get_window_is_normal (window) || is_chrome_window (window)) {
                ring.visible = false;
                return;
            }

            tracked = window;
            position_signal = window.position_changed.connect (() => update ());
            size_signal = window.size_changed.connect (() => update ());
            unmanaged_signal = window.unmanaged.connect (() => track (null));
            ring.visible = true;
            update ();
        }

        private void update () {
            if (tracked == null) {
                return;
            }

            var rect = tracked.get_frame_rect ();
            ring.set_position (rect.x, rect.y);
            ring.set_size (rect.width, rect.height);
            restack ();
        }

        // Mutter reparents a window's actor between window_group and
        // top_window_group (and back) whenever its always-on-top state
        // changes, rather than just reordering within one group — that's
        // why `restacked` (not just position/size_changed) has to trigger
        // this too. Re-deriving the ring's parent and sibling position from
        // the tracked window's actor every time, instead of assuming a
        // fixed group, keeps the ring directly above the focused window but
        // still below whatever else is genuinely stacked in front of it,
        // like an always-on-top window.
        private void restack () {
            if (tracked == null) {
                return;
            }

            var window_actor = tracked.get_compositor_private () as Clutter.Actor;
            if (window_actor == null) {
                return;
            }

            unowned Clutter.Actor? parent = window_actor.get_parent ();
            if (parent == null) {
                return;
            }

            if (ring.get_parent () != parent) {
                ring.get_parent ().remove_child (ring);
                parent.add_child (ring);
            }

            parent.set_child_above_sibling (ring, window_actor);
        }

        public void destroy () {
            if (tracked != null) {
                tracked.disconnect (position_signal);
                tracked.disconnect (size_signal);
                tracked.disconnect (unmanaged_signal);
            }

            if (do_focus_window_id != 0) {
                wm.get_display ().disconnect (do_focus_window_id);
                do_focus_window_id = 0;
            }

            if (restacked_id != 0) {
                wm.get_display ().disconnect (restacked_id);
                restacked_id = 0;
            }

            if (accent_color_id != 0) {
                Granite.Settings.get_default ().disconnect (accent_color_id);
                accent_color_id = 0;
            }

            ring.destroy ();
        }
    }
}
