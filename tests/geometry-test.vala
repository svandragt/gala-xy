using Gala.Plugins.Xy;

void test_next_fraction_width_steps_up () {
    double[] fractions = { 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0 };

    // At (near) 1/3 of a 900px area, the next step is 1/2.
    assert (Geometry.next_fraction_width (300, 900, fractions) == 450);

    // At 1/2, the next step is 2/3.
    assert (Geometry.next_fraction_width (450, 900, fractions) == 600);

    // At 2/3, it wraps back around to 1/3.
    assert (Geometry.next_fraction_width (600, 900, fractions) == 300);
}

void test_next_fraction_width_picks_closest_when_between_steps () {
    double[] fractions = { 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0 };

    // 340px is closer to 1/3 (300px) than 1/2 (450px) of a 900px area,
    // so it should be treated as sitting on the 1/3 step and advance to 1/2.
    assert (Geometry.next_fraction_width (340, 900, fractions) == 450);
}

void test_next_fraction_width_breaks_exact_ties_toward_lower_fraction () {
    double[] fractions = { 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0 };

    // 375px is exactly equidistant between 1/3 (300px) and 1/2 (450px) of
    // a 900px area. The comparison is strict-less-than, so the first
    // (lower) fraction wins the tie and the cycle still advances from it.
    assert (Geometry.next_fraction_width (375, 900, fractions) == 450);
}

void test_cap_delta_to_min_width_passes_through_when_room () {
    // Shrinking a 400px neighbor by 100px leaves it at 300px, well above
    // a 50px floor, so the delta is unchanged.
    assert (Geometry.cap_delta_to_min_width (400, 100, 50) == 100);
}

void test_cap_delta_to_min_width_caps_when_it_would_go_below_floor () {
    // Shrinking a 120px neighbor by 100px would take it to 20px, below
    // the 50px floor, so the delta is capped to leave it exactly at 50px.
    assert (Geometry.cap_delta_to_min_width (120, 100, 50) == 70);
}

void test_cap_delta_to_min_width_passes_through_at_exact_floor () {
    // Landing exactly on the floor (150 - 100 == 50) is not "below" it —
    // the check is strict-less-than, so this must NOT be capped further.
    assert (Geometry.cap_delta_to_min_width (150, 100, 50) == 100);
}

void test_cap_delta_to_min_width_passes_through_when_growing_neighbor () {
    // A negative delta grows the neighbor (this is the shape cycle_width()
    // produces when wrapping from a larger fraction back down to a
    // smaller one) — growing never risks the floor, so it's never capped.
    assert (Geometry.cap_delta_to_min_width (60, -200, 50) == -200);
}

void test_resize_delta_for_op_maps_right_edges_to_positive_one () {
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_E) == 1);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_NE) == 1);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_SE) == 1);
}

void test_resize_delta_for_op_maps_left_edges_to_negative_one () {
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_W) == -1);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_NW) == -1);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_SW) == -1);
}

void test_resize_delta_for_op_ignores_non_horizontal_ops () {
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_N) == 0);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.RESIZING_S) == 0);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.MOVING) == 0);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.NONE) == 0);
}

void test_resize_delta_for_op_ignores_keyboard_resizes () {
    // Keyboard-driven resizes are still resizes (is_resize_op() exempts
    // them from retile()), but they never drive a divider partner — only
    // an interactive mouse drag on a specific edge does.
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.KEYBOARD_RESIZING_E) == 0);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.KEYBOARD_RESIZING_W) == 0);
    assert (Geometry.resize_delta_for_op (Meta.GrabOp.KEYBOARD_RESIZING_UNKNOWN) == 0);
}

void test_is_resize_op_true_for_every_resize_variant () {
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_N));
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_S));
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_E));
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_W));
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_NE));
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_NW));
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_SE));
    assert (Geometry.is_resize_op (Meta.GrabOp.RESIZING_SW));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_UNKNOWN));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_N));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_S));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_E));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_W));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_NE));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_NW));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_SE));
    assert (Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_RESIZING_SW));
}

void test_is_resize_op_false_for_moving_and_none () {
    assert (!Geometry.is_resize_op (Meta.GrabOp.MOVING));
    assert (!Geometry.is_resize_op (Meta.GrabOp.MOVING_UNCONSTRAINED));
    assert (!Geometry.is_resize_op (Meta.GrabOp.KEYBOARD_MOVING));
    assert (!Geometry.is_resize_op (Meta.GrabOp.NONE));
}

void test_is_dropped_near_bottom_edge_true_when_flush_with_area_bottom () {
    // Area is (0, 0, 1000x900); a window ending exactly at y=900 is flush.
    assert (Geometry.is_dropped_near_bottom_edge (800, 100, 0, 900, 10));
}

void test_is_dropped_near_bottom_edge_true_within_threshold () {
    // Frame bottom at y=895, 5px short of the area's 900px bottom edge,
    // still within a 10px threshold.
    assert (Geometry.is_dropped_near_bottom_edge (795, 100, 0, 900, 10));
}

void test_is_dropped_near_bottom_edge_false_outside_threshold () {
    // Frame bottom at y=850, 50px short of the bottom edge — well outside
    // a 10px threshold, an ordinary drop elsewhere in the row.
    assert (!Geometry.is_dropped_near_bottom_edge (750, 100, 0, 900, 10));
}

void test_is_dropped_near_bottom_edge_accounts_for_area_offset () {
    // A non-zero area.y (e.g. a monitor below the primary one) shifts the
    // bottom edge accordingly.
    assert (Geometry.is_dropped_near_bottom_edge (1700, 100, 900, 900, 10));
    assert (!Geometry.is_dropped_near_bottom_edge (1600, 100, 900, 900, 10));
}

void test_float_shrink_geometry_shrinks_and_centres_a_full_height_window () {
    int height, y;
    assert (Geometry.float_shrink_geometry (1000, 40, 1000, 2.0 / 3.0, 8, out height, out y));
    assert (height == 667);
    // Equal gap above and below: (1000 - 667) / 2 = 166, offset by area.y.
    assert (y == 206);
}

void test_float_shrink_geometry_treats_near_full_height_as_full_height () {
    int height, y;
    // A few px short of the work area still counts — a retiled frame can
    // land marginally off.
    assert (Geometry.float_shrink_geometry (995, 0, 1000, 2.0 / 3.0, 8, out height, out y));
    assert (height == 667);
}

void test_float_shrink_geometry_leaves_an_already_short_window_alone () {
    int height, y;
    assert (!Geometry.float_shrink_geometry (500, 0, 1000, 2.0 / 3.0, 8, out height, out y));
    assert (height == 500);
}

public static int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/geometry/next_fraction_width/steps_up", test_next_fraction_width_steps_up);
    Test.add_func ("/geometry/next_fraction_width/picks_closest_when_between_steps",
        test_next_fraction_width_picks_closest_when_between_steps);
    Test.add_func ("/geometry/next_fraction_width/breaks_exact_ties_toward_lower_fraction",
        test_next_fraction_width_breaks_exact_ties_toward_lower_fraction);
    Test.add_func ("/geometry/cap_delta_to_min_width/passes_through_when_room",
        test_cap_delta_to_min_width_passes_through_when_room);
    Test.add_func ("/geometry/cap_delta_to_min_width/caps_when_it_would_go_below_floor",
        test_cap_delta_to_min_width_caps_when_it_would_go_below_floor);
    Test.add_func ("/geometry/cap_delta_to_min_width/passes_through_at_exact_floor",
        test_cap_delta_to_min_width_passes_through_at_exact_floor);
    Test.add_func ("/geometry/cap_delta_to_min_width/passes_through_when_growing_neighbor",
        test_cap_delta_to_min_width_passes_through_when_growing_neighbor);
    Test.add_func ("/geometry/resize_delta_for_op/maps_right_edges_to_positive_one",
        test_resize_delta_for_op_maps_right_edges_to_positive_one);
    Test.add_func ("/geometry/resize_delta_for_op/maps_left_edges_to_negative_one",
        test_resize_delta_for_op_maps_left_edges_to_negative_one);
    Test.add_func ("/geometry/resize_delta_for_op/ignores_non_horizontal_ops",
        test_resize_delta_for_op_ignores_non_horizontal_ops);
    Test.add_func ("/geometry/resize_delta_for_op/ignores_keyboard_resizes",
        test_resize_delta_for_op_ignores_keyboard_resizes);
    Test.add_func ("/geometry/is_resize_op/true_for_every_resize_variant",
        test_is_resize_op_true_for_every_resize_variant);
    Test.add_func ("/geometry/is_resize_op/false_for_moving_and_none",
        test_is_resize_op_false_for_moving_and_none);
    Test.add_func ("/geometry/is_dropped_near_bottom_edge/true_when_flush_with_area_bottom",
        test_is_dropped_near_bottom_edge_true_when_flush_with_area_bottom);
    Test.add_func ("/geometry/is_dropped_near_bottom_edge/true_within_threshold",
        test_is_dropped_near_bottom_edge_true_within_threshold);
    Test.add_func ("/geometry/is_dropped_near_bottom_edge/false_outside_threshold",
        test_is_dropped_near_bottom_edge_false_outside_threshold);
    Test.add_func ("/geometry/is_dropped_near_bottom_edge/accounts_for_area_offset",
        test_is_dropped_near_bottom_edge_accounts_for_area_offset);
    Test.add_func ("/geometry/float_shrink_geometry/shrinks_and_centres_a_full_height_window",
        test_float_shrink_geometry_shrinks_and_centres_a_full_height_window);
    Test.add_func ("/geometry/float_shrink_geometry/treats_near_full_height_as_full_height",
        test_float_shrink_geometry_treats_near_full_height_as_full_height);
    Test.add_func ("/geometry/float_shrink_geometry/leaves_an_already_short_window_alone",
        test_float_shrink_geometry_leaves_an_already_short_window_alone);

    return Test.run ();
}
