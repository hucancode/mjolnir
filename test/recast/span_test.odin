package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"

@(test)
test_span_allocation :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    // Create a small heightfield
    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Test adding a single span
    ok = recast.rc_add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span should succeed")

    // Check that the span was added
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Span should exist")
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(20))
    testing.expect_value(t, span.area, u32(nav_recast.RC_WALKABLE_AREA))
    testing.expect(t, span.next == nil, "Should be only span in column")
}

@(test)
test_span_merging :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add first span
    ok = recast.rc_add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding first span should succeed")

    // Add overlapping span (should merge)
    ok = recast.rc_add_span(hf, 5, 5, 15, 25, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding overlapping span should succeed")

    // Check that spans were merged
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Merged span should exist")
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(25))
    testing.expect(t, span.next == nil, "Should still be only one span after merge")
}

@(test)
test_span_non_overlapping :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add first span
    ok = recast.rc_add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding first span should succeed")

    // Add non-overlapping span (should create new span)
    ok = recast.rc_add_span(hf, 5, 5, 30, 40, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding non-overlapping span should succeed")

    // Check that we have two separate spans
    column_index := 5 + 5 * hf.width
    span1 := hf.spans[column_index]
    testing.expect(t, span1 != nil, "First span should exist")
    testing.expect_value(t, span1.smin, u32(10))
    testing.expect_value(t, span1.smax, u32(20))

    span2 := span1.next
    testing.expect(t, span2 != nil, "Second span should exist")
    testing.expect_value(t, span2.smin, u32(30))
    testing.expect_value(t, span2.smax, u32(40))
    testing.expect(t, span2.next == nil, "Should be last span")
}

@(test)
test_span_area_priority :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add span with lower priority area
    ok = recast.rc_add_span(hf, 5, 5, 10, 20, 10, 1)
    testing.expect(t, ok, "Adding first span should succeed")

    // Add overlapping span with higher priority area
    ok = recast.rc_add_span(hf, 5, 5, 15, 25, 20, 1)
    testing.expect(t, ok, "Adding higher priority span should succeed")

    // Check that the higher priority area was preserved
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Merged span should exist")
    testing.expect_value(t, span.area, u32(20))
}

@(test)
test_span_edge_cases :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Test adding span at grid boundaries
    ok = recast.rc_add_span(hf, 0, 0, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span at origin should succeed")

    ok = recast.rc_add_span(hf, 9, 9, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span at max coordinates should succeed")

    // Test maximum height span
    max_height := u16(nav_recast.RC_SPAN_MAX_HEIGHT)
    ok = recast.rc_add_span(hf, 5, 5, 0, max_height, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding max height span should succeed")

    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Max height span should exist")
    testing.expect_value(t, span.smax, u32(max_height))
}

@(test)
test_span_multiple_columns :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add spans in different columns
    for x in 0..<5 {
        for z in 0..<5 {
            ok = recast.rc_add_span(hf, i32(x), i32(z), u16(x*10), u16(x*10+10), nav_recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Adding span should succeed")
        }
    }

    // Verify spans were added correctly
    for x in 0..<5 {
        for z in 0..<5 {
            column_index := i32(x) + i32(z) * hf.width
            span := hf.spans[column_index]
            testing.expect(t, span != nil, "Span should exist")
            testing.expect_value(t, span.smin, u32(x*10))
            testing.expect_value(t, span.smax, u32(x*10+10))
        }
    }
}

@(test)
test_span_complex_merging :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Create a complex scenario with multiple overlapping spans
    // Add spans: [10-20], [30-40], [50-60]
    ok = recast.rc_add_span(hf, 5, 5, 10, 20, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 1 should succeed")

    ok = recast.rc_add_span(hf, 5, 5, 30, 40, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 2 should succeed")

    ok = recast.rc_add_span(hf, 5, 5, 50, 60, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 3 should succeed")

    // Add a span that bridges the gap between first two: [15-35]
    ok = recast.rc_add_span(hf, 5, 5, 15, 35, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding bridging span should succeed")

    // Should now have two spans: [10-40] and [50-60]
    column_index := 5 + 5 * hf.width
    span1 := hf.spans[column_index]
    testing.expect(t, span1 != nil, "First merged span should exist")
    testing.expect_value(t, span1.smin, u32(10))
    testing.expect_value(t, span1.smax, u32(40))

    span2 := span1.next
    testing.expect(t, span2 != nil, "Second span should exist")
    testing.expect_value(t, span2.smin, u32(50))
    testing.expect_value(t, span2.smax, u32(60))
    testing.expect(t, span2.next == nil, "Should be last span")
}
