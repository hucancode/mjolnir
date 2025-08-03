package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

// Helper to create a heightfield for testing
create_test_heightfield :: proc(width, height: i32) -> ^recast.Rc_Heightfield {
    hf := recast.rc_alloc_heightfield()
    if hf == nil do return nil
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(width), 10, f32(height)}
    cs := f32(1.0)
    ch := f32(0.5)
    
    ok := recast.rc_create_heightfield(hf, width, height, bmin, bmax, cs, ch)
    if !ok {
        recast.rc_free_heightfield(hf)
        return nil
    }
    
    return hf
}

// Helper to verify span list integrity
verify_span_list :: proc(t: ^testing.T, hf: ^recast.Rc_Heightfield, x, z: i32, expected_spans: []struct{smin: u32, smax: u32, area: u32}) {
    column_index := x + z * hf.width
    span := hf.spans[column_index]
    
    for i in 0..<len(expected_spans) {
        testing.expectf(t, span != nil, "Expected span %d but found nil", i)
        if span == nil do return
        
        testing.expect_value(t, span.smin, expected_spans[i].smin)
        testing.expect_value(t, span.smax, expected_spans[i].smax)
        testing.expect_value(t, span.area, expected_spans[i].area)
        
        span = span.next
    }
    
    testing.expectf(t, span == nil, "Expected %d spans but found more", len(expected_spans))
}

@(test)
test_span_merge_non_overlapping :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Add two non-overlapping spans
    ok := recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")
    
    ok = recast.rc_add_span(hf, 5, 5, 30, 40, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")
    
    // Verify we have two separate spans
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 20, recast.RC_WALKABLE_AREA},
        {30, 40, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_merge_exact_overlap :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Add two exactly overlapping spans
    ok := recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")
    
    ok = recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")
    
    // Should merge into one span with higher area ID
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 20, recast.RC_WALKABLE_AREA}, // Higher area ID wins
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_merge_partial_overlap :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Add two partially overlapping spans
    ok := recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")
    
    ok = recast.rc_add_span(hf, 5, 5, 15, 25, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")
    
    // Should merge into one extended span
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 25, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_merge_touching :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Add two spans that exactly touch (smax1 == smin2)
    ok := recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")
    
    ok = recast.rc_add_span(hf, 5, 5, 20, 30, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")
    
    // Should merge into one continuous span
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 30, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_merge_multiple_overlaps :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Add multiple spans that will all merge
    ok := recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 1")
    
    ok = recast.rc_add_span(hf, 5, 5, 30, 40, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 2")
    
    ok = recast.rc_add_span(hf, 5, 5, 50, 60, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 3")
    
    // Add a span that overlaps all of them
    ok = recast.rc_add_span(hf, 5, 5, 15, 55, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add merging span")
    
    // Should merge into one large span
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 60, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_merge_area_priority :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Test that higher area IDs take priority
    ok := recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")
    
    ok = recast.rc_add_span(hf, 5, 5, 15, 25, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")
    
    // Should merge with higher area ID
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 25, recast.RC_WALKABLE_AREA}, // Higher area ID wins
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_merge_threshold :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Test flag merge threshold
    ok := recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")
    
    // Add span that overlaps but with smax difference > threshold
    ok = recast.rc_add_span(hf, 5, 5, 15, 30, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")
    
    // Area WILL merge because after updating smax, the difference becomes 0
    // This matches C++ behavior where the check happens after potential smax update
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 30, recast.RC_WALKABLE_AREA}, // Higher area ID wins
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_insertion_order :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Add spans in reverse order
    ok := recast.rc_add_span(hf, 5, 5, 50, 60, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 1")
    
    ok = recast.rc_add_span(hf, 5, 5, 30, 40, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 2")
    
    ok = recast.rc_add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 3")
    
    // Should be sorted correctly
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 20, recast.RC_WALKABLE_AREA},
        {30, 40, recast.RC_WALKABLE_AREA},
        {50, 60, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

@(test)
test_span_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Test minimum values
    ok := recast.rc_add_span(hf, 0, 0, 0, 1, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add min span")
    
    // Test maximum values
    max_height := u16(recast.RC_SPAN_MAX_HEIGHT - 1)
    ok = recast.rc_add_span(hf, 9, 9, max_height-1, max_height, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add max span")
    
    // Verify both spans exist
    expected_min := []struct{smin: u32, smax: u32, area: u32}{
        {0, 1, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 0, 0, expected_min)
    
    expected_max := []struct{smin: u32, smax: u32, area: u32}{
        {u32(max_height-1), u32(max_height), recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 9, 9, expected_max)
}

@(test)
test_span_invalid_inputs :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.rc_free_heightfield(hf)
    
    // Test out of bounds coordinates
    ok := recast.rc_add_span(hf, -1, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with negative x")
    
    ok = recast.rc_add_span(hf, 5, -1, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with negative z")
    
    ok = recast.rc_add_span(hf, 10, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with x >= width")
    
    ok = recast.rc_add_span(hf, 5, 10, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with z >= height")
    
    // Test invalid span range (min > max)
    ok = recast.rc_add_span(hf, 5, 5, 20, 10, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with min > max")
}