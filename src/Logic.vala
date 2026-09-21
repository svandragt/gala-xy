namespace Gala.Plugins.Xy {
    // Pure logic pulled out of WindowSwitcher, FocusRing and SwitcherPanel so
    // it can be unit tested without a live Mutter session (see
    // tests/logic-test.vala). No Meta.*, Clutter.* or Gala.* types anywhere
    // in this file — that's what keeps it linkable into the test binary.
    public class Logic {
        public const int ROW_HEIGHT = 32;
        public const int PADDING = 12;
        public const int TEXT_PADDING = 10;
        public const int MIN_WIDTH = 240;
        public const int MAX_WIDTH = 480;

        // The single held-down modifier of an accelerator mask (Super, for
        // the Super+arrow defaults): the highest set bit, isolated the way
        // gnome-shell and Gala's own switcher do. The panel watches this key
        // so it can stay up until the user lets go of it.
        public static uint primary_modifier (uint mask) {
            if (mask == 0) {
                return 0;
            }

            uint primary = 1;
            while (mask > 1) {
                mask >>= 1;
                primary <<= 1;
            }
            return primary;
        }

        // Re-derives the next position from the actually-focused window's
        // index, not a stored one: that's what lets stepping keep advancing
        // through the ring even though each activate() reshuffles Mutter's
        // own MRU underneath. Total over count == 0, the guard the caller
        // used to get for free from an earlier early-return.
        public static int step_index (int count, int current, int delta) {
            if (count == 0) {
                return 0;
            }

            return (current + delta + count) % count;
        }

        // Keeps the frozen order but drops any id that has since closed;
        // reseeds from live MRU (in live's own order) when there's no
        // usable snapshot left.
        public static uint[] reconcile_order (uint[] frozen, uint[] live) {
            uint[] ordered = {};
            foreach (uint seq in frozen) {
                foreach (uint live_seq in live) {
                    if (live_seq == seq) {
                        ordered += seq;
                        break;
                    }
                }
            }

            if (ordered.length < 2) {
                return live;
            }

            return ordered;
        }

        // A window matching either an excluded title keyword (case-
        // insensitive substring) or an excluded app id (exact, case-
        // sensitive) is treated as system chrome.
        public static bool is_excluded (string? title, string? app_id, string[] keywords, string[] app_ids) {
            string lowered_title = (title ?? "").down ();
            foreach (unowned string keyword in keywords) {
                if (keyword != "" && lowered_title.contains (keyword.down ())) {
                    return true;
                }
            }

            if (app_id != null) {
                foreach (unowned string excluded_id in app_ids) {
                    if (app_id == excluded_id) {
                        return true;
                    }
                }
            }

            return false;
        }

        // Widest title (capped) decides the width; one row per window
        // decides the height.
        public static void panel_size (int text_width, int row_count, out int width, out int height) {
            width = text_width + 2 * PADDING + 2 * TEXT_PADDING;
            width = int.max (MIN_WIDTH, int.min (MAX_WIDTH, width));
            height = row_count * ROW_HEIGHT + 2 * PADDING;
        }
    }
}
