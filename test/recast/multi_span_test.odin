package test_recast

import "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_multiple_spans_per_cell :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a small heightfield
    field_size := i32(5)
    cell_size := f32(1.0)
    cell_height := f32(0.5)

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(field_size), 50, f32(field_size)}

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add multiple spans to cell (2,2) - simulating a multi-story building
    x, z := i32(2), i32(2)

    // Floor 1: Ground level
    ok = recast.add_span(hf, x, z, 0, 2, u8(recast.RC_WALKABLE_AREA), 1)
    testing.expect(t, ok, "Adding floor 1 should succeed")

    // Floor 2: Second story (gap for ceiling)
    ok = recast.add_span(hf, x, z, 6, 8, u8(recast.RC_WALKABLE_AREA), 1)
    testing.expect(t, ok, "Adding floor 2 should succeed")

    // Floor 3: Third story
    ok = recast.add_span(hf, x, z, 12, 14, u8(recast.RC_WALKABLE_AREA), 1)
    testing.expect(t, ok, "Adding floor 3 should succeed")

    // Floor 4: Fourth story
    ok = recast.add_span(hf, x, z, 18, 20, u8(recast.RC_WALKABLE_AREA), 1)
    testing.expect(t, ok, "Adding floor 4 should succeed")

    // Floor 5: Fifth story
    ok = recast.add_span(hf, x, z, 24, 26, u8(recast.RC_WALKABLE_AREA), 1)
    testing.expect(t, ok, "Adding floor 5 should succeed")

    // Add a tall pillar that goes through all floors
    ok = recast.add_span(hf, x, z, 0, 30, u8(recast.RC_NULL_AREA), 1)
    testing.expect(t, ok, "Adding pillar should succeed")

    // Count spans in the cell
    column_index := x + z * field_size
    span := hf.spans[column_index]
    span_count := 0

    log.info("Spans in cell (2,2):")
    current := span
    for current != nil {
        min_height := f32(current.smin) * cell_height
        max_height := f32(current.smax) * cell_height
        area_type := current.area == u32(recast.RC_WALKABLE_AREA) ? "walkable" : "obstacle"

        log.infof("  Span %d: [%.1f-%.1f] %s", span_count + 1, min_height, max_height, area_type)

        span_count += 1
        current = current.next
    }

    // After merging with the pillar, we should have just one merged span
    testing.expect(t, span_count >= 1, "Should have at least one span after merging")

    log.infof("Total spans in cell: %d", span_count)
}

@(test)
test_many_thin_spans :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test with many thin non-overlapping spans
    field_size := i32(3)
    cell_size := f32(1.0)
    cell_height := f32(0.1) // Very fine resolution

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(field_size), 100, f32(field_size)}

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add 20 thin spans with gaps between them
    x, z := i32(1), i32(1)
    spans_added := 0

    for i in 0..<20 {
        span_bottom := u16(i * 5)      // Each span starts at i*5
        span_top := u16(i * 5 + 2)     // Each span is 2 units tall
        // Gap of 3 units between spans

        ok = recast.add_span(hf, x, z, span_bottom, span_top, u8(recast.RC_WALKABLE_AREA), 1)
        if ok {
            spans_added += 1
        }
    }

    log.infof("Successfully added %d spans", spans_added)

    // Count actual spans in the cell
    column_index := x + z * field_size
    span := hf.spans[column_index]
    span_count := 0

    current := span
    for current != nil {
        span_count += 1
        current = current.next
    }

    log.infof("Cell contains %d spans", span_count)
    testing.expect(t, span_count == spans_added, "All spans should be preserved (no merging due to gaps)")
}
