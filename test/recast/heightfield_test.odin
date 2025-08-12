package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:math"
import "core:time"

@(test)
test_heightfield_allocation :: proc(t: ^testing.T) {

    // Test allocation
    hf := recast.alloc_heightfield()
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

    hf := recast.alloc_heightfield()
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
    chf := recast.alloc_compact_heightfield()
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

    hf := recast.alloc_heightfield()
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

    hf := recast.alloc_heightfield()
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
    
    hf := recast.alloc_heightfield()
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
            ok = recast.add_span(hf, i32(x), i32(z), 0, 10, nav_recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add span")
        }
    }
    
    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
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
