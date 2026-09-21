using Gala.Plugins.Xy;
using Xy;

void test_primary_modifier_zero_mask_returns_zero () {
    assert (Logic.primary_modifier (0) == 0);
}

void test_primary_modifier_single_modifier_returns_itself () {
    // A single set bit (e.g. Control, 0b100) is already isolated.
    assert (Logic.primary_modifier (4) == 4);
}

void test_primary_modifier_several_modifiers_returns_highest_bit () {
    // Super (0b1000) + Shift (0b0001) isolates to Super alone.
    assert (Logic.primary_modifier (9) == 8);
}

void test_step_index_forward_wraps_at_the_end () {
    assert (Logic.step_index (5, 4, 1) == 0);
}

void test_step_index_backward_wraps_at_the_start () {
    assert (Logic.step_index (5, 0, -1) == 4);
}

void test_step_index_mid_list_step () {
    assert (Logic.step_index (5, 2, 1) == 3);
}

void test_step_index_single_item_list_stays_put () {
    assert (Logic.step_index (1, 0, 1) == 0);
    assert (Logic.step_index (1, 0, -1) == 0);
}

void test_step_index_empty_list_returns_zero () {
    assert (Logic.step_index (0, 0, 1) == 0);
}

void test_reconcile_order_all_survive_keeps_frozen_order () {
    uint[] frozen = { 1, 2, 3 };
    uint[] live = { 3, 1, 2 };

    uint[] result = Logic.reconcile_order (frozen, live);
    assert (result.length == 3);
    assert (result[0] == 1);
    assert (result[1] == 2);
    assert (result[2] == 3);
}

void test_reconcile_order_some_dropped_keeps_survivors_in_frozen_order () {
    uint[] frozen = { 1, 2, 3 };
    uint[] live = { 1, 3 };

    uint[] result = Logic.reconcile_order (frozen, live);
    assert (result.length == 2);
    assert (result[0] == 1);
    assert (result[1] == 3);
}

void test_reconcile_order_fewer_than_two_survive_reseeds_to_live_order () {
    uint[] frozen = { 1, 2 };
    uint[] live = { 5, 6, 7 };

    uint[] result = Logic.reconcile_order (frozen, live);
    assert (result.length == 3);
    assert (result[0] == 5);
    assert (result[1] == 6);
    assert (result[2] == 7);
}

void test_reconcile_order_empty_frozen_reseeds_to_live_order () {
    uint[] frozen = {};
    uint[] live = { 1, 2, 3 };

    uint[] result = Logic.reconcile_order (frozen, live);
    assert (result.length == 3);
    assert (result[0] == 1);
    assert (result[1] == 2);
    assert (result[2] == 3);
}

void test_is_excluded_title_match_is_case_insensitive_substring () {
    string[] keywords = { "WingPanel" };
    string[] app_ids = {};
    assert (Logic.is_excluded ("My wingpanel Window", null, keywords, app_ids));
}

void test_is_excluded_empty_keyword_never_matches () {
    string[] keywords = { "" };
    string[] app_ids = {};
    assert (!Logic.is_excluded ("Anything", null, keywords, app_ids));
}

void test_is_excluded_app_id_match_is_exact () {
    string[] keywords = {};
    string[] app_ids = { "com.example.app" };
    assert (Logic.is_excluded (null, "com.example.app", keywords, app_ids));
    assert (!Logic.is_excluded (null, "com.example.app2", keywords, app_ids));
}

void test_is_excluded_null_title_does_not_crash () {
    string[] keywords = { "wingpanel" };
    string[] app_ids = {};
    assert (!Logic.is_excluded (null, null, keywords, app_ids));
}

void test_is_excluded_null_app_id_is_skipped () {
    string[] keywords = {};
    string[] app_ids = { "com.example.app" };
    assert (!Logic.is_excluded ("Some Window", null, keywords, app_ids));
}

void test_is_excluded_no_match_returns_false () {
    string[] keywords = { "foo" };
    string[] app_ids = { "bar" };
    assert (!Logic.is_excluded ("Random Window", "com.example.app", keywords, app_ids));
}

void test_panel_size_below_min_clamps_up () {
    int width, height;
    Logic.panel_size (0, 1, out width, out height);
    assert (width == Logic.MIN_WIDTH);
}

void test_panel_size_above_max_clamps_down () {
    int width, height;
    Logic.panel_size (1000, 1, out width, out height);
    assert (width == Logic.MAX_WIDTH);
}

void test_panel_size_middle_value_passes_through_with_padding_added () {
    int width, height;
    // 300 + 2 * PADDING + 2 * TEXT_PADDING == 344, comfortably between
    // MIN_WIDTH (240) and MAX_WIDTH (480), so it should pass straight
    // through unclamped.
    Logic.panel_size (300, 1, out width, out height);
    assert (width == 300 + 2 * Logic.PADDING + 2 * Logic.TEXT_PADDING);
}

void test_panel_size_height_scales_with_row_count () {
    int width, height;
    Logic.panel_size (300, 3, out width, out height);
    assert (height == 3 * Logic.ROW_HEIGHT + 2 * Logic.PADDING);
}

void test_panel_size_zero_rows_is_just_padding () {
    int width, height;
    Logic.panel_size (300, 0, out width, out height);
    assert (height == 2 * Logic.PADDING);
}

// Strv.to_text's GLib.Value parameter isn't `ref` (it has to match GSettings'
// plain-C-function-pointer delegate type exactly, see Strv.vala), so an
// ordinary Vala call copies `value` onto the stack before taking its address
// and the mutation never reaches the caller's own variable — only real
// GSettings machinery, calling the compiled symbol directly with a genuine
// GValue*, gets that write. This extern binds straight to that symbol so the
// test can exercise the same real write GSettings performs.
[CCode (cname = "xy_strv_to_text")]
extern bool strv_to_text_raw (void* value, GLib.Variant variant, void* user_data);

void test_strv_round_trips_through_text_and_back () {
    var variant = new GLib.Variant.strv ({ "a", "b", "c" });
    var value = GLib.Value (typeof (string));
    strv_to_text_raw (&value, variant, null);
    assert (value.get_string () == "a, b, c");

    var result = Strv.to_strv (value, new GLib.VariantType ("as"), null);
    string[] items = result.get_strv ();
    assert (items.length == 3);
    assert (items[0] == "a");
    assert (items[1] == "b");
    assert (items[2] == "c");
}

void test_strv_to_strv_strips_whitespace () {
    var value = GLib.Value (typeof (string));
    value.set_string (" a , b ");

    var result = Strv.to_strv (value, new GLib.VariantType ("as"), null);
    string[] items = result.get_strv ();
    assert (items.length == 2);
    assert (items[0] == "a");
    assert (items[1] == "b");
}

void test_strv_to_strv_drops_empty_entries () {
    var value = GLib.Value (typeof (string));
    value.set_string ("a,,b");

    var result = Strv.to_strv (value, new GLib.VariantType ("as"), null);
    string[] items = result.get_strv ();
    assert (items.length == 2);
    assert (items[0] == "a");
    assert (items[1] == "b");
}

void test_strv_to_strv_empty_string_yields_empty_array () {
    var value = GLib.Value (typeof (string));
    value.set_string ("");

    var result = Strv.to_strv (value, new GLib.VariantType ("as"), null);
    assert (result.get_strv ().length == 0);
}

public static int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/logic/primary_modifier/zero_mask_returns_zero", test_primary_modifier_zero_mask_returns_zero);
    Test.add_func ("/logic/primary_modifier/single_modifier_returns_itself",
        test_primary_modifier_single_modifier_returns_itself);
    Test.add_func ("/logic/primary_modifier/several_modifiers_returns_highest_bit",
        test_primary_modifier_several_modifiers_returns_highest_bit);
    Test.add_func ("/logic/step_index/forward_wraps_at_the_end", test_step_index_forward_wraps_at_the_end);
    Test.add_func ("/logic/step_index/backward_wraps_at_the_start", test_step_index_backward_wraps_at_the_start);
    Test.add_func ("/logic/step_index/mid_list_step", test_step_index_mid_list_step);
    Test.add_func ("/logic/step_index/single_item_list_stays_put", test_step_index_single_item_list_stays_put);
    Test.add_func ("/logic/step_index/empty_list_returns_zero", test_step_index_empty_list_returns_zero);
    Test.add_func ("/logic/reconcile_order/all_survive_keeps_frozen_order",
        test_reconcile_order_all_survive_keeps_frozen_order);
    Test.add_func ("/logic/reconcile_order/some_dropped_keeps_survivors_in_frozen_order",
        test_reconcile_order_some_dropped_keeps_survivors_in_frozen_order);
    Test.add_func ("/logic/reconcile_order/fewer_than_two_survive_reseeds_to_live_order",
        test_reconcile_order_fewer_than_two_survive_reseeds_to_live_order);
    Test.add_func ("/logic/reconcile_order/empty_frozen_reseeds_to_live_order",
        test_reconcile_order_empty_frozen_reseeds_to_live_order);
    Test.add_func ("/logic/is_excluded/title_match_is_case_insensitive_substring",
        test_is_excluded_title_match_is_case_insensitive_substring);
    Test.add_func ("/logic/is_excluded/empty_keyword_never_matches", test_is_excluded_empty_keyword_never_matches);
    Test.add_func ("/logic/is_excluded/app_id_match_is_exact", test_is_excluded_app_id_match_is_exact);
    Test.add_func ("/logic/is_excluded/null_title_does_not_crash", test_is_excluded_null_title_does_not_crash);
    Test.add_func ("/logic/is_excluded/null_app_id_is_skipped", test_is_excluded_null_app_id_is_skipped);
    Test.add_func ("/logic/is_excluded/no_match_returns_false", test_is_excluded_no_match_returns_false);
    Test.add_func ("/logic/panel_size/below_min_clamps_up", test_panel_size_below_min_clamps_up);
    Test.add_func ("/logic/panel_size/above_max_clamps_down", test_panel_size_above_max_clamps_down);
    Test.add_func ("/logic/panel_size/middle_value_passes_through_with_padding_added",
        test_panel_size_middle_value_passes_through_with_padding_added);
    Test.add_func ("/logic/panel_size/height_scales_with_row_count", test_panel_size_height_scales_with_row_count);
    Test.add_func ("/logic/panel_size/zero_rows_is_just_padding", test_panel_size_zero_rows_is_just_padding);
    Test.add_func ("/logic/strv/round_trips_through_text_and_back", test_strv_round_trips_through_text_and_back);
    Test.add_func ("/logic/strv/to_strv_strips_whitespace", test_strv_to_strv_strips_whitespace);
    Test.add_func ("/logic/strv/to_strv_drops_empty_entries", test_strv_to_strv_drops_empty_entries);
    Test.add_func ("/logic/strv/to_strv_empty_string_yields_empty_array",
        test_strv_to_strv_empty_string_yields_empty_array);

    return Test.run ();
}
