package test_recast

import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

// ================================
// SECTION 1: FILTER LOW HANGING WALKABLE OBSTACLES
// ================================

@(test)
test_filter_low_hanging_obstacles_basic :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable span at ground level
    ok = recast.add_span(hf, 2, 2, 0, 2, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add walkable span")

    // Add non-walkable span just above it (obstacle)
    ok = recast.add_span(hf, 2, 2, 3, 4, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add obstacle span")

    // Apply filter with walkable_climb = 2
    recast.filter_low_hanging_walkable_obstacles(2, hf)

    // The obstacle should now be walkable because it's within climb height
    column_index := 2 + 2 * hf.width
    span := hf.spans[column_index]

    // Find the obstacle span (should be second in list)
    obstacle_span := span.next
    testing.expect(t, obstacle_span != nil, "Should have obstacle span")
    if obstacle_span != nil {
        testing.expect(t, obstacle_span.area == recast.RC_WALKABLE_AREA,
                      "Obstacle should be marked walkable after filter")
    }

    log.info("✓ Basic low hanging obstacles filter test passed")
}

@(test)
test_filter_low_hanging_obstacles_too_high :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable span at ground level
    ok = recast.add_span(hf, 2, 2, 0, 2, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add walkable span")

    // Add non-walkable span too high above it
    ok = recast.add_span(hf, 2, 2, 5, 7, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add high obstacle span")

    // Apply filter with walkable_climb = 2 (span difference is 3, too high)
    recast.filter_low_hanging_walkable_obstacles(2, hf)

    // The obstacle should remain non-walkable
    column_index := 2 + 2 * hf.width
    span := hf.spans[column_index]
    obstacle_span := span.next
    testing.expect(t, obstacle_span != nil, "Should have obstacle span")
    if obstacle_span != nil {
        testing.expect(t, obstacle_span.area == recast.RC_NULL_AREA,
                      "High obstacle should remain non-walkable")
    }

    log.info("✓ Too high obstacles filter test passed")
}

@(test)
test_filter_low_hanging_obstacles_multiple_spans :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create complex span column: walkable, obstacle (low), walkable, obstacle (high)
    ok = recast.add_span(hf, 2, 2, 0, 2, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add ground walkable span")

    ok = recast.add_span(hf, 2, 2, 3, 4, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add low obstacle")

    ok = recast.add_span(hf, 2, 2, 5, 7, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add upper walkable span")

    ok = recast.add_span(hf, 2, 2, 10, 12, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add high obstacle")

    // Apply filter with walkable_climb = 2
    recast.filter_low_hanging_walkable_obstacles(2, hf)

    // Check results: low obstacle should be walkable, high obstacle should not
    column_index := 2 + 2 * hf.width
    span := hf.spans[column_index]

    // Ground span (walkable)
    testing.expect(t, span.area == recast.RC_WALKABLE_AREA, "Ground should be walkable")

    // Low obstacle (should be converted to walkable)
    span = span.next
    testing.expect(t, span != nil && span.area == recast.RC_WALKABLE_AREA,
                  "Low obstacle should be walkable")

    // Upper walkable (should remain walkable)
    span = span.next
    testing.expect(t, span != nil && span.area == recast.RC_WALKABLE_AREA,
                  "Upper walkable should remain walkable")

    // High obstacle (should remain non-walkable because gap from upper walkable is too big)
    span = span.next
    testing.expect(t, span != nil && span.area == recast.RC_NULL_AREA,
                  "High obstacle should remain non-walkable")

    log.info("✓ Multiple spans low hanging obstacles filter test passed")
}

// ================================
// SECTION 2: FILTER LEDGE SPANS
// ================================

@(test)
test_filter_ledge_spans_basic :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create heightfield and compact heightfield for ledge filtering
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create a ledge scenario: walkable area with drop-off
    // Add walkable spans in center and some neighbors, but not all
    ok = recast.add_span(hf, 2, 2, 0, 2, recast.RC_WALKABLE_AREA, 1) // Center
    testing.expect(t, ok, "Failed to add center span")

    ok = recast.add_span(hf, 1, 2, 0, 2, recast.RC_WALKABLE_AREA, 1) // Left neighbor
    testing.expect(t, ok, "Failed to add left neighbor")

    ok = recast.add_span(hf, 2, 1, 0, 2, recast.RC_WALKABLE_AREA, 1) // Bottom neighbor
    testing.expect(t, ok, "Failed to add bottom neighbor")

    // Missing right (3,2) and top (2,3) neighbors - this creates a ledge

    // Build compact heightfield
    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Apply ledge filter with walkable_height = 4 (must be able to stand)
    recast.filter_ledge_spans(4, 2, hf)

    // Check if spans near ledges are filtered out
    // Center span should be filtered because it has missing neighbors (ledge)
    center_idx := 2 + 2 * hf.width
    span := hf.spans[center_idx]
    if span != nil {
        // Area should be set to RC_NULL_AREA if it's a dangerous ledge
        log.infof("Center span area after ledge filter: %d", span.area)
    }

    log.info("✓ Basic ledge spans filter test completed")
}

@(test)
test_filter_ledge_spans_safe_area :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create a safe area with all neighbors present
    for x in 1..=3 {
        for z in 1..=3 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 2, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add safe area span")
        }
    }

    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Apply ledge filter
    recast.filter_ledge_spans(4, 2, hf)

    // All spans in the safe area should remain walkable
    center_idx := 2 + 2 * hf.width
    span := hf.spans[center_idx]
    testing.expect(t, span != nil, "Should have spans in safe area")
    if span != nil {
        testing.expect(t, span.area == recast.RC_WALKABLE_AREA,
                      "Safe area should remain walkable")
    }

    log.info("✓ Safe area ledge filter test passed")
}

// ================================
// SECTION 3: FILTER WALKABLE LOW HEIGHT SPANS
// ================================

@(test)
test_filter_walkable_low_height_spans_basic :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable span with low ceiling (insufficient height clearance)
    ok = recast.add_span(hf, 2, 2, 0, 2, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add ground span")

    // Add ceiling span very close above (height = 2 units)
    ok = recast.add_span(hf, 2, 2, 4, 6, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add ceiling span")

    // Apply filter with walkable_height = 4 (requires 4 units clearance)
    recast.filter_walkable_low_height_spans(4, hf)

    // Ground span should be filtered out due to insufficient clearance
    column_index := 2 + 2 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Should have span")
    if span != nil {
        // The span should be marked as non-walkable
        testing.expect(t, span.area == recast.RC_NULL_AREA,
                      "Span with low clearance should be filtered")
    }

    log.info("✓ Basic low height filter test passed")
}

@(test)
test_filter_walkable_low_height_spans_sufficient_height :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable span with sufficient ceiling height
    ok = recast.add_span(hf, 2, 2, 0, 2, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add ground span")

    // Add ceiling span with sufficient clearance (6 units above ground span max)
    ok = recast.add_span(hf, 2, 2, 8, 10, recast.RC_NULL_AREA, 1)
    testing.expect(t, ok, "Failed to add ceiling span")

    // Apply filter with walkable_height = 4
    recast.filter_walkable_low_height_spans(4, hf)

    // Ground span should remain walkable
    column_index := 2 + 2 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Should have span")
    if span != nil {
        testing.expect(t, span.area == recast.RC_WALKABLE_AREA,
                      "Span with sufficient clearance should remain walkable")
    }

    log.info("✓ Sufficient height clearance test passed")
}

@(test)
test_filter_walkable_low_height_no_ceiling :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable span with no ceiling (open sky)
    ok = recast.add_span(hf, 2, 2, 0, 2, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add ground span")

    // Apply filter with walkable_height = 4
    recast.filter_walkable_low_height_spans(4, hf)

    // Ground span should remain walkable (no ceiling constraint)
    column_index := 2 + 2 * hf.width
    span := hf.spans[column_index]
    testing.expect(t, span != nil, "Should have span")
    if span != nil {
        testing.expect(t, span.area == recast.RC_WALKABLE_AREA,
                      "Span with no ceiling should remain walkable")
    }

    log.info("✓ No ceiling constraint test passed")
}

// ================================
// SECTION 4: FILTER INTERACTIONS
// ================================

@(test)
test_filter_interactions_combined :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test applying multiple filters in sequence to ensure they work together
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create complex scenario with multiple filter conditions
    // Ground level walkable area
    for x in 2..=7 {
        for z in 2..=7 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 2, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add ground span")
        }
    }

    // Add some low hanging obstacles
    ok = recast.add_span(hf, 4, 4, 3, 4, recast.RC_NULL_AREA, 1) // Low obstacle
    testing.expect(t, ok, "Failed to add low obstacle")

    // Add low ceiling in one area
    ok = recast.add_span(hf, 6, 6, 3, 5, recast.RC_NULL_AREA, 1) // Low ceiling
    testing.expect(t, ok, "Failed to add low ceiling")

    // Apply filters in sequence
    recast.filter_low_hanging_walkable_obstacles(2, hf)
    recast.filter_walkable_low_height_spans(4, hf)

    // Build compact heightfield for ledge filtering
    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    recast.filter_ledge_spans(4, 2, hf)

    // Verify that combined filters worked correctly
    // Check that we have reasonable walkable area left
    walkable_count := 0
    for i in 0..<(hf.width * hf.height) {
        if span := hf.spans[i]; span != nil {
            if span.area == recast.RC_WALKABLE_AREA {
                walkable_count += 1
            }
        }
    }

    testing.expect(t, walkable_count > 0, "Should have some walkable area after all filters")
    log.infof("✓ Combined filters test passed. %d walkable spans remaining", walkable_count)
}
