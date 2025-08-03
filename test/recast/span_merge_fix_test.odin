package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_span_merge_algorithm_correctness :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create a small heightfield
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)
    
    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")
    
    // Test 1: Add non-overlapping spans in order
    ok = recast.rc_add_span(hf, 5, 5, 0, 5, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "First span should succeed")
    
    ok = recast.rc_add_span(hf, 5, 5, 10, 15, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Second span should succeed")
    
    ok = recast.rc_add_span(hf, 5, 5, 20, 25, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Third span should succeed")
    
    // Verify we have 3 separate spans
    column_index := 5 + 5 * 10
    span := hf.spans[column_index]
    count := 0
    for s := span; s != nil; s = s.next {
        count += 1
    }
    testing.expect_value(t, count, 3)
    
    // Test 2: Add overlapping span that should merge all three
    ok = recast.rc_add_span(hf, 5, 5, 0, 25, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Merging span should succeed")
    
    // Should now have just one merged span
    span = hf.spans[column_index]
    count = 0
    for s := span; s != nil; s = s.next {
        count += 1
    }
    testing.expect_value(t, count, 1)
    testing.expect_value(t, u16(span.smin), u16(0))
    testing.expect_value(t, u16(span.smax), u16(25))
}

@(test)
test_span_merge_out_of_order :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test adding spans out of order
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)
    
    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")
    
    // Add spans in reverse order
    ok = recast.rc_add_span(hf, 5, 5, 20, 25, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "High span should succeed")
    
    ok = recast.rc_add_span(hf, 5, 5, 10, 15, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Middle span should succeed")
    
    ok = recast.rc_add_span(hf, 5, 5, 0, 5, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Low span should succeed")
    
    // Verify spans are in correct order
    column_index := 5 + 5 * 10
    span := hf.spans[column_index]
    
    // First span should be 0-5
    testing.expect(t, span != nil, "First span should exist")
    testing.expect_value(t, u16(span.smin), u16(0))
    testing.expect_value(t, u16(span.smax), u16(5))
    
    // Second span should be 10-15
    span = span.next
    testing.expect(t, span != nil, "Second span should exist")
    testing.expect_value(t, u16(span.smin), u16(10))
    testing.expect_value(t, u16(span.smax), u16(15))
    
    // Third span should be 20-25
    span = span.next
    testing.expect(t, span != nil, "Third span should exist")
    testing.expect_value(t, u16(span.smin), u16(20))
    testing.expect_value(t, u16(span.smax), u16(25))
    
    // No more spans
    testing.expect(t, span.next == nil, "Should be no more spans")
}

@(test)
test_span_partial_merge :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test partial merging scenarios
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)
    
    ok := recast.rc_create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")
    
    // Add three spans
    ok = recast.rc_add_span(hf, 5, 5, 0, 10, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok)
    
    ok = recast.rc_add_span(hf, 5, 5, 20, 30, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok)
    
    ok = recast.rc_add_span(hf, 5, 5, 40, 50, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok)
    
    // Add a span that bridges the first two
    ok = recast.rc_add_span(hf, 5, 5, 5, 25, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Bridging span should succeed")
    
    // Should now have 2 spans: [0-30] and [40-50]
    column_index := 5 + 5 * 10
    span := hf.spans[column_index]
    
    testing.expect(t, span != nil, "First merged span should exist")
    testing.expect_value(t, u16(span.smin), u16(0))
    testing.expect_value(t, u16(span.smax), u16(30))
    
    span = span.next
    testing.expect(t, span != nil, "Second span should exist")
    testing.expect_value(t, u16(span.smin), u16(40))
    testing.expect_value(t, u16(span.smax), u16(50))
    
    testing.expect(t, span.next == nil, "Should be no more spans")
}