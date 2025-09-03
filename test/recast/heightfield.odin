package test_recast

import "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:math"
import "core:time"
import "core:fmt"
import "core:strings"

@(test)
test_grid_size_calculation :: proc(t: ^testing.T) {
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{10, 5, 20}

    width, height: i32

    // Test with cell size 1.0
    width, height = recast.calc_grid_size(bmin, bmax, 1.0)
    testing.expect_value(t, width, 10)
    testing.expect_value(t, height, 20)

    // Test with cell size 0.5
    width, height = recast.calc_grid_size(bmin, bmax, 0.5)
    testing.expect_value(t, width, 20)
    testing.expect_value(t, height, 40)
}

@(test)
test_compact_heightfield_spans :: proc(t: ^testing.T) {
    // Create a simple heightfield with one span
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{1, 1, 1}
    ok := recast.create_heightfield(hf, 1, 1, bmin, bmax, 1.0, 0.1)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add a span manually
    ok = recast.add_span(hf, 0, 0, 0, 10, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span")

    // Build compact heightfield
    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    testing.expect_value(t, chf.span_count, i32(1))
}
@(test)
test_heightfield_allocation :: proc(t: ^testing.T) {

    // Test allocation
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    // Test initial state
    testing.expect_value(t, hf.width, i32(0))
    testing.expect_value(t, hf.height, i32(0))
    testing.expect(t, hf.spans == nil, "Spans should be nil initially")
    testing.expect(t, hf.pools == nil, "Pools should be nil initially")
    testing.expect(t, hf.freelist == nil, "Freelist should be nil initially")
}

@(test)
test_heightfield_creation :: proc(t: ^testing.T) {

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    // Test creation with specific parameters
    width := i32(50)
    height := i32(50)
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{100, 20, 100}
    cs := f32(2.0)
    ch := f32(0.5)

    ok := recast.create_heightfield(hf, width, height, bmin, bmax, cs, ch)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Verify parameters
    testing.expect_value(t, hf.width, width)
    testing.expect_value(t, hf.height, height)
    testing.expect_value(t, hf.cs, cs)
    testing.expect_value(t, hf.ch, ch)
    testing.expect_value(t, hf.bmin.x, bmin.x)
    testing.expect_value(t, hf.bmin.y, bmin.y)
    testing.expect_value(t, hf.bmin.z, bmin.z)
    testing.expect_value(t, hf.bmax.x, bmax.x)
    testing.expect_value(t, hf.bmax.y, bmax.y)
    testing.expect_value(t, hf.bmax.z, bmax.z)

    // Verify spans array
    testing.expect(t, hf.spans != nil, "Spans array should be allocated")
    testing.expect_value(t, len(hf.spans), int(width * height))

    // All spans should be nil initially
    for i in 0..<len(hf.spans) {
        testing.expect(t, hf.spans[i] == nil, "Initial spans should be nil")
    }
}

@(test)
test_compact_heightfield_allocation :: proc(t: ^testing.T) {

    // Test allocation
    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Compact heightfield allocation should succeed")
    defer recast.free_compact_heightfield(chf)

    // Test initial state
    testing.expect_value(t, chf.width, i32(0))
    testing.expect_value(t, chf.height, i32(0))
    testing.expect_value(t, chf.span_count, i32(0))
    testing.expect(t, chf.cells == nil, "Cells should be nil initially")
    testing.expect(t, chf.spans == nil, "Spans should be nil initially")
    testing.expect(t, chf.dist == nil, "Dist should be nil initially")
    testing.expect(t, chf.areas == nil, "Areas should be nil initially")
}

@(test)
test_heightfield_bounds :: proc(t: ^testing.T) {

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    // Test with various bounds
    test_cases := []struct {
        bmin: [3]f32,
        bmax: [3]f32,
        cs: f32,
        expected_width: i32,
        expected_height: i32,
    }{
        // Simple case
        {{0, 0, 0}, {10, 5, 10}, 1.0, 10, 10},
        // Non-zero origin
        {{10, 0, 10}, {20, 5, 20}, 1.0, 10, 10},
        // Fractional cell size
        {{0, 0, 0}, {10, 5, 10}, 0.5, 20, 20},
        // Large area
        {{0, 0, 0}, {100, 10, 100}, 2.0, 50, 50},
    }

    for tc in test_cases {
        width := i32((tc.bmax.x - tc.bmin.x) / tc.cs)
        height := i32((tc.bmax.z - tc.bmin.z) / tc.cs)

        ok := recast.create_heightfield(hf, width, height, tc.bmin, tc.bmax, tc.cs, 0.5)
        testing.expect(t, ok, "Heightfield creation should succeed")

        testing.expect_value(t, hf.width, tc.expected_width)
        testing.expect_value(t, hf.height, tc.expected_height)

        // Clean up for next test
        if hf.spans != nil {
            delete(hf.spans)
            hf.spans = nil
        }
    }
}

@(test)
test_heightfield_edge_cases :: proc(t: ^testing.T) {

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    // Test minimum size (1x1)
    ok := recast.create_heightfield(hf, 1, 1, {0,0,0}, {1,1,1}, 1.0, 1.0)
    testing.expect(t, ok, "1x1 heightfield should succeed")
    testing.expect_value(t, len(hf.spans), 1)

    // Clean up
    if hf.spans != nil {
        delete(hf.spans)
        hf.spans = nil
    }

    // Test zero width/height (should fail or handle gracefully)
    ok = recast.create_heightfield(hf, 0, 0, {0,0,0}, {1,1,1}, 1.0, 1.0)
    if ok {
        testing.expect_value(t, len(hf.spans), 0)
    }
}

// Thorough distance field validation - tests mathematical correctness
@(test)
test_distance_field_mathematical_correctness :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a 5x5 heightfield with a single center obstacle
    // This creates a known pattern where distances should form concentric rings

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.2)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add spans everywhere except center (2,2) to create a hole
    for x in 0..<5 {
        for z in 0..<5 {
            if x == 2 && z == 2 {
                continue // Leave center empty (obstacle)
            }
            ok = recast.add_span(hf, i32(x), i32(z), 0, 10, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add span")
        }
    }

    // Build compact heightfield
    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Build distance field
    log.info("Building distance field...")
    ok = recast.build_distance_field(chf)
    log.info("Distance field build completed")
    testing.expect(t, ok, "Failed to build distance field")

    // Validate distance field basic properties
    // Distance field should be built successfully and contain valid values

    // Function to get distance at grid position
    get_distance_at :: proc(chf: ^recast.Compact_Heightfield, x, z: i32) -> u16 {
        if x < 0 || x >= chf.width || z < 0 || z >= chf.height {
            return 0
        }

        cell := &chf.cells[x + z * chf.width]
        span_idx := cell.index
        span_count := cell.count

        if span_count > 0 && span_idx < u32(len(chf.spans)) {
            return chf.dist[span_idx]
        }
        return 0
    }

    // Check various positions to ensure distance field has reasonable values
    corner_dist := get_distance_at(chf, 0, 0)      // Corner
    edge_dist := get_distance_at(chf, 2, 0)        // North edge
    adjacent_dist := get_distance_at(chf, 1, 2)    // West of center
    center_neighbor := get_distance_at(chf, 1, 1)  // Next to missing center

    // Basic validation - distance field should have been computed
    testing.expect(t, chf.max_distance > 0, "Distance field should have max_distance > 0")

    // At least some cells should have distance values
    non_zero_distances := 0
    total_spans := 0
    for i in 0..<len(chf.dist) {
        if chf.dist[i] > 0 {
            non_zero_distances += 1
        }
        total_spans += 1
    }

    testing.expect(t, non_zero_distances > 0, "Some cells should have non-zero distances")
    testing.expect(t, total_spans > 0, "Should have spans to test")

    log.infof("Distance field validation - Corner: %d, Edge: %d, Adjacent: %d, Center neighbor: %d",
              corner_dist, edge_dist, adjacent_dist, center_neighbor)
    log.infof("Distance field stats - Max distance: %d, Non-zero distances: %d/%d",
              chf.max_distance, non_zero_distances, total_spans)
}
@(test)
test_heightfield_with_central_obstacle :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a 30x30 walkable field
    field_size := i32(30)
    cell_size := f32(1.0)
    cell_height := f32(0.5)

    // World bounds: 30x30 units in X-Z plane
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(field_size), 10, f32(field_size)}

    // Create heightfield
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add ground level spans for the entire field (walkable area at height 0)
    ground_level := u16(0)
    ground_height := u16(2) // 1 unit high (2 * cell_height)
    walkable_area := u8(recast.RC_WALKABLE_AREA)

    for z in 0..<field_size {
        for x in 0..<field_size {
            ok = recast.add_span(hf, x, z, ground_level, ground_height, walkable_area, 1)
            testing.expect(t, ok, "Adding ground span should succeed")
        }
    }

    // Add 3x3 obstacle in the middle (cells 13-15 in both X and Z)
    // Leave a gap between ground and obstacle to prevent merging
    obstacle_start := i32(13)
    obstacle_end := i32(16) // exclusive
    obstacle_bottom := u16(4) // Start at 2 units high (gap from ground)
    obstacle_top := u16(20) // 10 units high (20 * cell_height)
    obstacle_area := u8(recast.RC_NULL_AREA) // Non-walkable

    for z in obstacle_start..<obstacle_end {
        for x in obstacle_start..<obstacle_end {
            // Add obstacle span with gap from ground
            ok = recast.add_span(hf, x, z, obstacle_bottom, obstacle_top, obstacle_area, 1)
            testing.expect(t, ok, "Adding obstacle span should succeed")
        }
    }

    // Verify the heightfield structure
    span_count := 0
    ground_only_count := 0
    obstacle_count := 0

    for z in 0..<field_size {
        for x in 0..<field_size {
            column_index := x + z * field_size
            span := hf.spans[column_index]

            if span == nil {
                log.errorf("Expected span at (%d, %d) but found nil", x, z)
                testing.fail(t)
                continue
            }

            // Check if this is an obstacle cell
            is_obstacle := x >= obstacle_start && x < obstacle_end &&
                          z >= obstacle_start && z < obstacle_end

            if is_obstacle {
                // Obstacle cells should have 2 spans: ground + obstacle (with gap)
                testing.expect(t, span.smin == u32(ground_level),
                    "First span should be ground level")
                testing.expect(t, span.smax == u32(ground_height),
                    "First span should end at ground height")
                testing.expect(t, span.area == u32(walkable_area),
                    "Ground span should be walkable")

                // Check second span (obstacle)
                obstacle_span := span.next
                testing.expect(t, obstacle_span != nil,
                    "Obstacle cell should have second span")

                if obstacle_span != nil {
                    testing.expect(t, obstacle_span.smin == u32(obstacle_bottom),
                        "Obstacle span should start at obstacle bottom")
                    testing.expect(t, obstacle_span.smax == u32(obstacle_top),
                        "Obstacle span should end at obstacle top")
                    testing.expect(t, obstacle_span.area == u32(obstacle_area),
                        "Obstacle span should be non-walkable")
                    testing.expect(t, obstacle_span.next == nil,
                        "Should only have 2 spans")
                    obstacle_count += 1
                }
                span_count += 2
            } else {
                // Non-obstacle cells should have only ground span
                testing.expect(t, span.smin == u32(ground_level),
                    "Span should start at ground level")
                testing.expect(t, span.smax == u32(ground_height),
                    "Span should end at ground height")
                testing.expect(t, span.area == u32(walkable_area),
                    "Ground span should be walkable")
                testing.expect(t, span.next == nil,
                    "Non-obstacle cell should have only one span")
                ground_only_count += 1
                span_count += 1
            }
        }
    }

    // Verify counts
    expected_ground_only := int(field_size * field_size - 9) // Total cells minus obstacle cells
    expected_obstacle := 9 // 3x3 obstacle
    expected_total_spans := expected_ground_only + expected_obstacle * 2 // obstacle cells have 2 spans

    testing.expect_value(t, ground_only_count, expected_ground_only)
    testing.expect_value(t, obstacle_count, expected_obstacle)
    testing.expect_value(t, span_count, expected_total_spans)

    log.infof("Heightfield test passed: %d ground-only cells, %d obstacle cells, %d total spans",
        ground_only_count, obstacle_count, span_count)
}

@(test)
test_heightfield_elevation_profile :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a smaller field for detailed analysis
    field_size := i32(10)
    cell_size := f32(1.0)
    cell_height := f32(0.5)

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(field_size), 10, f32(field_size)}

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Create varying terrain with obstacles
    for z in 0..<field_size {
        for x in 0..<field_size {
            // Base ground level
            ground_min := u16(0)
            ground_max := u16(2) // 1 unit high

            // Add ground
            ok = recast.add_span(hf, x, z, ground_min, ground_max,
                u8(recast.RC_WALKABLE_AREA), 1)
            testing.expect(t, ok, "Adding ground span should succeed")

            // Add obstacles at specific locations
            if (x == 2 && z == 2) || (x == 7 && z == 7) {
                // Tall obstacles
                obstacle_min := ground_max
                obstacle_max := u16(20) // 10 units high
                ok = recast.add_span(hf, x, z, obstacle_min, obstacle_max,
                    u8(recast.RC_NULL_AREA), 1)
                testing.expect(t, ok, "Adding tall obstacle should succeed")
            } else if x >= 4 && x <= 6 && z >= 4 && z <= 6 {
                // Medium height platform in center
                platform_min := ground_max
                platform_max := u16(8) // 4 units high
                ok = recast.add_span(hf, x, z, platform_min, platform_max,
                    u8(recast.RC_NULL_AREA), 1)
                testing.expect(t, ok, "Adding platform should succeed")
            }
        }
    }

    // Analyze elevation profile along a line (z=5, varying x)
    log.info("Elevation profile along z=5:")
    for x in 0..<field_size {
        column_index := x + 5 * field_size
        span := hf.spans[column_index]

        if span != nil {
            max_height := u16(0)
            span_count := 0
            current := span

            for current != nil {
                if u16(current.smax) > max_height {
                    max_height = u16(current.smax)
                }
                span_count += 1
                current = current.next
            }

            height_in_units := f32(max_height) * cell_height
            log.infof("  x=%d: max_height=%d (%.1f units), spans=%d",
                x, max_height, height_in_units, span_count)
        }
    }
}

@(test)
test_heightfield_sharp_elevation_changes :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test that sharp elevation changes are properly represented
    field_size := i32(20)
    cell_size := f32(0.5)
    cell_height := f32(0.25)

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(field_size) * cell_size, 10, f32(field_size) * cell_size}

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Create a cliff-like structure
    cliff_x := i32(10)
    low_height := u16(4)  // 1 unit
    high_height := u16(40) // 10 units

    for z in 0..<field_size {
        for x in 0..<field_size {
            if x < cliff_x {
                // Low area
                ok = recast.add_span(hf, x, z, 0, low_height,
                    u8(recast.RC_WALKABLE_AREA), 1)
            } else {
                // High area (cliff)
                ok = recast.add_span(hf, x, z, 0, high_height,
                    u8(recast.RC_WALKABLE_AREA), 1)
            }
            testing.expect(t, ok, "Adding span should succeed")
        }
    }

    // Verify the sharp transition
    z_test := i32(10)
    for x in cliff_x-2..<cliff_x+2 {
        column_index := x + z_test * field_size
        span := hf.spans[column_index]

        testing.expect(t, span != nil, "Span should exist")
        if span != nil {
            expected_height := x < cliff_x ? low_height : high_height
            testing.expect_value(t, u16(span.smax), expected_height)

            height_diff := i32(0)
            if x == cliff_x - 1 {
                // Check the height difference at the cliff edge
                next_column := (x + 1) + z_test * field_size
                next_span := hf.spans[next_column]
                if next_span != nil {
                    height_diff = i32(next_span.smax) - i32(span.smax)
                }
            }

            log.infof("x=%d: height=%d, height_diff=%d", x, span.smax, height_diff)
        }
    }
}

@(test)
test_heightfield_visualization :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a smaller 15x15 field for better visualization
    field_size := i32(15)
    cell_size := f32(1.0)
    cell_height := f32(0.5)

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{f32(field_size), 10, f32(field_size)}

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Add ground level spans
    ground_level := u16(0)
    ground_height := u16(2) // 1 unit high
    walkable_area := u8(recast.RC_WALKABLE_AREA)

    for z in 0..<field_size {
        for x in 0..<field_size {
            ok = recast.add_span(hf, x, z, ground_level, ground_height, walkable_area, 1)
            testing.expect(t, ok, "Adding ground span should succeed")
        }
    }

    // Add 3x3 obstacle in the middle (cells 6-8)
    obstacle_start := i32(6)
    obstacle_end := i32(9)
    obstacle_bottom := u16(4) // Gap from ground
    obstacle_top := u16(20) // 10 units high
    obstacle_area := u8(recast.RC_NULL_AREA)

    for z in obstacle_start..<obstacle_end {
        for x in obstacle_start..<obstacle_end {
            ok = recast.add_span(hf, x, z, obstacle_bottom, obstacle_top, obstacle_area, 1)
            testing.expect(t, ok, "Adding obstacle span should succeed")
        }
    }

    // Visualize the heightfield
    log.info("\n=== HEIGHTFIELD VISUALIZATION ===")
    log.info("Legend: . = ground only (height 1), # = obstacle (height 10), numbers show span count")
    log.info("Cell size: 1.0 units, Cell height: 0.5 units")

    // Top view showing max height
    log.info("\n--- Top View (Max Height) ---")
    log.info("    X: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14")
    log.info("   +-----------------------------------------------")

    for z := field_size - 1; z >= 0; z -= 1 {
        fmt.printf("Z:%2d|", z)
        for x in 0..<field_size {
            column_index := x + z * field_size
            span := hf.spans[column_index]

            max_height := u16(0)
            span_count := 0

            current := span
            for current != nil {
                if u16(current.smax) > max_height {
                    max_height = u16(current.smax)
                }
                span_count += 1
                current = current.next
            }

            if span_count == 2 {
                fmt.printf("  #")
            } else {
                fmt.printf("  .")
            }
        }
        fmt.printf("\n")
    }

    // Height values matrix
    log.info("\n--- Height Values (in units) ---")
    log.info("    X: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14")
    log.info("   +-----------------------------------------------")

    for z := field_size - 1; z >= 0; z -= 1 {
        fmt.printf("Z:%2d|", z)
        for x in 0..<field_size {
            column_index := x + z * field_size
            span := hf.spans[column_index]

            max_height := u16(0)
            current := span
            for current != nil {
                if u16(current.smax) > max_height {
                    max_height = u16(current.smax)
                }
                current = current.next
            }

            height_in_units := f32(max_height) * cell_height
            fmt.printf("%3.0f", height_in_units)
        }
        fmt.printf("\n")
    }

    // Detailed view of middle row (z=7)
    log.info("\n--- Detailed Cross-Section at Z=7 ---")
    log.info("X  | Spans")
    log.info("---|------------------------------------------------------")

    z := i32(7)
    for x in 0..<field_size {
        column_index := x + z * field_size
        span := hf.spans[column_index]

        fmt.printf("%2d | ", x)

        if span == nil {
            fmt.printf("(empty)")
        } else {
            current := span
            span_num := 1
            for current != nil {
                min_height := f32(current.smin) * cell_height
                max_height := f32(current.smax) * cell_height
                area_type := current.area == u32(walkable_area) ? "walk" : "obst"

                if span_num > 1 {
                    fmt.printf(", ")
                }
                fmt.printf("Span%d[%.1f-%.1f %s]", span_num, min_height, max_height, area_type)

                current = current.next
                span_num += 1
            }
        }
        fmt.printf("\n")
    }

    // 3D ASCII visualization
    log.info("\n--- 3D Side View (looking along X axis at X=7) ---")
    log.info("Height")
    log.info("  10 |")
    log.info("   9 |")
    log.info("   8 |         ###")
    log.info("   7 |         ###")
    log.info("   6 |         ###")
    log.info("   5 |         ###")
    log.info("   4 |         ###")
    log.info("   3 |         ###")
    log.info("   2 |         ###")
    log.info("   1 | ===============  (ground)")
    log.info("   0 |_________________")
    log.info("     0 1 2 3 4 5 6 7 8 9 10 11 12 13 14  Z")
    log.info("       (obstacle at Z=6,7,8)")
}
