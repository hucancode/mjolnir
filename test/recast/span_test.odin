package test_recast

import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

// ================================
// SECTION 1: UNIT TESTS - BIT OPERATIONS
// ================================

// Unit Test: Verify span bit packing/unpacking with hard-coded inputs
@(test)
test_span_bit_operations :: proc(t: ^testing.T) {
    span := recast.Span{}

    // Test setting and getting smin
    span.smin = 100
    testing.expect_value(t, span.smin, u32(100))

    // Test setting and getting smax
    span.smax = 200
    testing.expect_value(t, span.smax, u32(200))
    testing.expect_value(t, span.smin, u32(100)) // Ensure smin unchanged

    // Test setting and getting area
    span.area = 42
    testing.expect_value(t, span.area, u32(42))
    testing.expect_value(t, span.smin, u32(100)) // Ensure smin unchanged
    testing.expect_value(t, span.smax, u32(200)) // Ensure smax unchanged

    // Test max values
    max_height := u32(recast.RC_SPAN_MAX_HEIGHT)
    span.smin = max_height
    span.smax = max_height
    testing.expect_value(t, span.smin, max_height)
    testing.expect_value(t, span.smax, max_height)

    // Test area max value (6 bits = 63)
    span.area = 63
    testing.expect_value(t, span.area, u32(63))
}

// Unit Test: Verify compact cell bit operations
@(test)
test_compact_cell_bit_operations :: proc(t: ^testing.T) {
    cell := recast.Compact_Cell{}

    // Test setting and getting index
    cell.index = 12345
    testing.expect_value(t, cell.index, u32(12345))

    // Test setting and getting count
    cell.count = 42
    testing.expect_value(t, cell.count, u8(42))
    testing.expect_value(t, cell.index, u32(12345)) // Ensure index unchanged

    // Test max values
    max_index := u32(0x00FFFFFF) // 24 bits
    cell.index = max_index
    testing.expect_value(t, cell.index, max_index)

    max_count := u8(255) // 8 bits
    cell.count = max_count
    testing.expect_value(t, cell.count, max_count)
}

// Unit Test: Verify compact span bit operations
@(test)
test_compact_span_bit_operations :: proc(t: ^testing.T) {
    span := recast.Compact_Span{}

    // Test y and reg (direct fields)
    span.y = 1000
    span.reg = 500
    testing.expect_value(t, span.y, u16(1000))
    testing.expect_value(t, span.reg, u16(500))

    // Test connection data
    span.con = 0x123456
    testing.expect_value(t, span.con, u32(0x123456))

    // Test height
    span.h = 100
    testing.expect_value(t, span.h, u8(100))
    testing.expect_value(t, span.con, u32(0x123456)) // Ensure con unchanged

    // Test max values
    max_con := u32(0x00FFFFFF) // 24 bits
    span.con = max_con
    testing.expect_value(t, span.con, max_con)

    max_h := u8(255) // 8 bits
    span.h = max_h
    testing.expect_value(t, span.h, max_h)
}

// ================================
// SECTION 2: UNIT TESTS - BASIC OPERATIONS
// ================================

// Unit Test: Basic span allocation
@(test)
test_span_allocation :: proc(t: ^testing.T) {
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    // Create a small heightfield
    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Test adding a single span
    ok = recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span should succeed")

    // Check that the span was added
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Span should exist")
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(20))
    testing.expect_value(t, span.area, u32(recast.RC_WALKABLE_AREA))
    testing.expect(t, span.next == nil, "Should be only span in column")
}

// Unit Test: Invalid span inputs
@(test)
test_span_invalid_inputs :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Test out of bounds coordinates
    ok = recast.add_span(hf, -1, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with negative x")

    ok = recast.add_span(hf, 5, -1, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with negative z")

    ok = recast.add_span(hf, 10, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with x >= width")

    ok = recast.add_span(hf, 5, 10, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with z >= height")

    // Test invalid span range (min > max)
    ok = recast.add_span(hf, 5, 5, 20, 10, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, !ok, "Should fail with min > max")
}

// Unit Test: Edge case values
@(test)
test_span_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Test minimum values
    ok = recast.add_span(hf, 0, 0, 0, 1, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add min span")

    // Test maximum values
    max_height := u16(recast.RC_SPAN_MAX_HEIGHT - 1)
    ok = recast.add_span(hf, 9, 9, max_height-1, max_height, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add max span")

    // Verify both spans exist
    span := hf.spans[0]
    testing.expect(t, span != nil, "Min span should exist")
    testing.expect_value(t, span.smin, u32(0))
    testing.expect_value(t, span.smax, u32(1))

    span = hf.spans[9 + 9 * 10]
    testing.expect(t, span != nil, "Max span should exist")
    testing.expect_value(t, span.smin, u32(max_height-1))
    testing.expect_value(t, span.smax, u32(max_height))
}

// ================================
// SECTION 3: INTEGRATION TESTS - SPAN MERGING
// ================================

// Helper to create a heightfield for testing
create_test_heightfield :: proc(width, height: i32) -> ^recast.Heightfield {
    hf := new(recast.Heightfield)
    if hf == nil do return nil

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(width), 10, f32(height)}
    cs := f32(1.0)
    ch := f32(0.5)

    ok := recast.create_heightfield(hf, width, height, bmin, bmax, cs, ch)
    if !ok {
        recast.free_heightfield(hf)
        return nil
    }

    return hf
}

// Helper to verify span list integrity
verify_span_list :: proc(t: ^testing.T, hf: ^recast.Heightfield, x, z: i32, expected_spans: []struct{smin: u32, smax: u32, area: u32}) {
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

// Integration Test: Basic span merging
@(test)
test_span_merging :: proc(t: ^testing.T) {
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add first span
    ok = recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding first span should succeed")

    // Add overlapping span (should merge)
    ok = recast.add_span(hf, 5, 5, 15, 25, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding overlapping span should succeed")

    // Check that spans were merged
    column_index := 5 + 5 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Merged span should exist")
    testing.expect_value(t, span.smin, u32(10))
    testing.expect_value(t, span.smax, u32(25))
    testing.expect(t, span.next == nil, "Should still be only one span after merge")
}

// Integration Test: Non-overlapping spans
@(test)
test_span_non_overlapping :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Add two non-overlapping spans
    ok := recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")

    ok = recast.add_span(hf, 5, 5, 30, 40, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")

    // Verify we have two separate spans
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 20, recast.RC_WALKABLE_AREA},
        {30, 40, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Exact overlap merging
@(test)
test_span_merge_exact_overlap :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Add two exactly overlapping spans
    ok := recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")

    ok = recast.add_span(hf, 5, 5, 10, 20, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")

    // Should merge into one span with higher area ID
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 20, recast.RC_WALKABLE_AREA}, // Higher area ID wins
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Partial overlap merging
@(test)
test_span_merge_partial_overlap :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Add two partially overlapping spans
    ok := recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")

    ok = recast.add_span(hf, 5, 5, 15, 25, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")

    // Should merge into one extended span
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 25, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Touching spans merge
@(test)
test_span_merge_touching :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Add two spans that exactly touch (smax1 == smin2)
    ok := recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")

    ok = recast.add_span(hf, 5, 5, 20, 30, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")

    // Should merge into one continuous span
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 30, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Multiple overlaps
@(test)
test_span_merge_multiple_overlaps :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Add multiple spans that will all merge
    ok := recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 1")

    ok = recast.add_span(hf, 5, 5, 30, 40, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 2")

    ok = recast.add_span(hf, 5, 5, 50, 60, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 3")

    // Add a span that overlaps all of them
    ok = recast.add_span(hf, 5, 5, 15, 55, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add merging span")

    // Should merge into one large span
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 60, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Area priority during merge
@(test)
test_span_area_priority :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Test that higher area IDs take priority
    ok := recast.add_span(hf, 5, 5, 10, 20, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")

    ok = recast.add_span(hf, 5, 5, 15, 25, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")

    // Should merge with higher area ID
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 25, recast.RC_WALKABLE_AREA}, // Higher area ID wins
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Merge threshold behavior
@(test)
test_span_merge_threshold :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Test flag merge threshold
    ok := recast.add_span(hf, 5, 5, 10, 20, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add first span")

    // Add span that overlaps but with smax difference > threshold
    ok = recast.add_span(hf, 5, 5, 15, 30, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add second span")

    // Area WILL merge because after updating smax, the difference becomes 0
    // This matches C++ behavior where the check happens after potential smax update
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 30, recast.RC_WALKABLE_AREA}, // Higher area ID wins
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Insertion order independence
@(test)
test_span_insertion_order :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := create_test_heightfield(10, 10)
    testing.expect(t, hf != nil, "Failed to create heightfield")
    defer recast.free_heightfield(hf)

    // Add spans in reverse order
    ok := recast.add_span(hf, 5, 5, 50, 60, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 1")

    ok = recast.add_span(hf, 5, 5, 30, 40, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 2")

    ok = recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 3")

    // Should be sorted correctly
    expected := []struct{smin: u32, smax: u32, area: u32}{
        {10, 20, recast.RC_WALKABLE_AREA},
        {30, 40, recast.RC_WALKABLE_AREA},
        {50, 60, recast.RC_WALKABLE_AREA},
    }
    verify_span_list(t, hf, 5, 5, expected)
}

// Integration Test: Algorithm correctness
@(test)
test_span_merge_algorithm_correctness :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a small heightfield
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Test 1: Add non-overlapping spans in order
    ok = recast.add_span(hf, 5, 5, 0, 5, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "First span should succeed")

    ok = recast.add_span(hf, 5, 5, 10, 15, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Second span should succeed")

    ok = recast.add_span(hf, 5, 5, 20, 25, recast.RC_WALKABLE_AREA, 1)
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
    ok = recast.add_span(hf, 5, 5, 0, 25, recast.RC_WALKABLE_AREA, 1)
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

// Integration Test: Out of order additions
@(test)
test_span_merge_out_of_order :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test adding spans out of order
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add spans in reverse order
    ok = recast.add_span(hf, 5, 5, 20, 25, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "High span should succeed")

    ok = recast.add_span(hf, 5, 5, 10, 15, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Middle span should succeed")

    ok = recast.add_span(hf, 5, 5, 0, 5, recast.RC_WALKABLE_AREA, 1)
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

// Integration Test: Partial merge scenarios
@(test)
test_span_partial_merge :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test partial merging scenarios
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add three spans
    ok = recast.add_span(hf, 5, 5, 0, 10, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok)

    ok = recast.add_span(hf, 5, 5, 20, 30, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok)

    ok = recast.add_span(hf, 5, 5, 40, 50, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok)

    // Add a span that bridges the first two
    ok = recast.add_span(hf, 5, 5, 5, 25, recast.RC_WALKABLE_AREA, 1)
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

// ================================
// SECTION 4: END-TO-END TESTS - COMPLEX SCENARIOS
// ================================

// End-to-End Test: Multiple columns with spans
@(test)
test_span_multiple_columns :: proc(t: ^testing.T) {
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add spans in different columns
    for x in 0..<5 {
        for z in 0..<5 {
            ok = recast.add_span(hf, i32(x), i32(z), u16(x*10), u16(x*10+10), recast.RC_WALKABLE_AREA, 1)
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

// End-to-End Test: Complex merging scenario
@(test)
test_span_complex_merging :: proc(t: ^testing.T) {
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Create a complex scenario with multiple overlapping spans
    // Add spans: [10-20], [30-40], [50-60]
    ok = recast.add_span(hf, 5, 5, 10, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 1 should succeed")

    ok = recast.add_span(hf, 5, 5, 30, 40, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 2 should succeed")

    ok = recast.add_span(hf, 5, 5, 50, 60, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Adding span 3 should succeed")

    // Add a span that bridges the gap between first two: [15-35]
    ok = recast.add_span(hf, 5, 5, 15, 35, recast.RC_WALKABLE_AREA, 1)
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

// Test span merging behavior with flag threshold - validates merging algorithm correctness
@(test)
test_span_merging_with_flag_threshold :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf: recast.Heightfield
    success := recast.create_heightfield(&hf, 10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.2)
    testing.expect(t, success, "Failed to create heightfield")
    defer recast.free_heightfield(&hf)

    // Test case 1: Merging spans with area flag threshold
    success = recast.add_span(&hf, 5, 5, 10, 20, 1, 2)
    testing.expect(t, success, "Failed to add first span")

    // Add overlapping span with area 2, within merge threshold
    success = recast.add_span(&hf, 5, 5, 15, 21, 2, 2)
    testing.expect(t, success, "Failed to add second span")

    // Check result - should have one merged span
    span := hf.spans[5 + 5 * hf.width]
    testing.expect(t, span != nil, "No span at expected location")
    if span != nil {
        testing.expect_value(t, span.smin, u32(10))
        testing.expect_value(t, span.smax, u32(21))
        testing.expect_value(t, span.area, u32(2)) // Should take max area
        testing.expect(t, span.next == nil, "Should have no next span after merge")
    }

    // Test case 2: Multiple overlapping spans
    // Clear the column
    for s := hf.spans[5 + 5 * hf.width]; s != nil; {
        next := s.next
        recast.free_span(&hf, s)
        s = next
    }
    hf.spans[5 + 5 * hf.width] = nil

    // Add three overlapping spans that should all merge
    success = recast.add_span(&hf, 5, 5, 10, 15, 1, 5)
    testing.expect(t, success, "Failed to add span 1 for test 3")

    success = recast.add_span(&hf, 5, 5, 12, 18, 2, 5)
    testing.expect(t, success, "Failed to add span 2 for test 3")

    success = recast.add_span(&hf, 5, 5, 14, 20, 3, 5)
    testing.expect(t, success, "Failed to add span 3 for test 3")

    // Should have one merged span covering the full range
    span = hf.spans[5 + 5 * hf.width]
    testing.expect(t, span != nil, "No span at expected location for test 3")
    if span != nil {
        testing.expect_value(t, span.smin, u32(10))
        testing.expect_value(t, span.smax, u32(20))
        testing.expect_value(t, span.area, u32(3)) // Area should be max of all merged spans when within threshold
        testing.expect(t, span.next == nil, "Should have single merged span")
    }
}

// Thorough heightfield span merging validation - tests complex merging logic
@(test)
test_span_merging_complex_scenarios :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test complex span merging with multiple overlapping spans at different heights
    // This validates the correctness of the span merging algorithm

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 3, 3, {0,0,0}, {3,3,3}, 1.0, 0.2)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add multiple overlapping spans at the same cell (1,1) with different height ranges
    x, z := i32(1), i32(1)

    // Span 1: height 0-10 (floor)
    ok = recast.add_span(hf, x, z, 0, 10, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 1")

    // Span 2: height 15-25 (platform above floor)
    ok = recast.add_span(hf, x, z, 15, 25, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 2")

    // Span 3: height 5-20 (overlapping span that should merge/clip)
    ok = recast.add_span(hf, x, z, 5, 20, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span 3")

    // Validate the resulting span structure
    // The merging algorithm should handle overlaps correctly

    spans := hf.spans[x + z * hf.width]
    testing.expect(t, spans != nil, "Cell should have spans after merging")

    // Count spans and validate heights
    span_count := 0
    current_span := spans
    min_smin := u32(999999)
    max_smax := u32(0)

    for current_span != nil {
        span_count += 1
        smin := current_span.smin
        smax := current_span.smax

        // Validate span integrity
        testing.expect(t, smax > smin, "Span max should be greater than min")

        min_smin = min(min_smin, smin)
        max_smax = max(max_smax, smax)

        current_span = current_span.next

        // Prevent infinite loops
        if span_count > 10 {
            testing.expect(t, false, "Too many spans - possible infinite loop")
            break
        }
    }

    // Validate span merging results
    testing.expect(t, span_count >= 1 && span_count <= 3,
                  "Merged spans should result in 1-3 final spans")
    testing.expect(t, min_smin <= 5, "Minimum span should start near original minimum")
    testing.expect(t, max_smax >= 20, "Maximum span should extend to original maximum")

    log.infof("Span merging validation - %d final spans, height range: %d to %d",
              span_count, min_smin, max_smax)
}
