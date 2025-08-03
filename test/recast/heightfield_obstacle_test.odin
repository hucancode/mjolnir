package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

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
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)
    
    ok := recast.rc_create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")
    
    // Add ground level spans for the entire field (walkable area at height 0)
    ground_level := u16(0)
    ground_height := u16(2) // 1 unit high (2 * cell_height)
    walkable_area := u8(recast.RC_WALKABLE_AREA)
    
    for z in 0..<field_size {
        for x in 0..<field_size {
            ok = recast.rc_add_span(hf, x, z, ground_level, ground_height, walkable_area, 1)
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
            ok = recast.rc_add_span(hf, x, z, obstacle_bottom, obstacle_top, obstacle_area, 1)
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
    
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)
    
    ok := recast.rc_create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")
    
    // Create varying terrain with obstacles
    for z in 0..<field_size {
        for x in 0..<field_size {
            // Base ground level
            ground_min := u16(0)
            ground_max := u16(2) // 1 unit high
            
            // Add ground
            ok = recast.rc_add_span(hf, x, z, ground_min, ground_max, 
                u8(recast.RC_WALKABLE_AREA), 1)
            testing.expect(t, ok, "Adding ground span should succeed")
            
            // Add obstacles at specific locations
            if (x == 2 && z == 2) || (x == 7 && z == 7) {
                // Tall obstacles
                obstacle_min := ground_max
                obstacle_max := u16(20) // 10 units high
                ok = recast.rc_add_span(hf, x, z, obstacle_min, obstacle_max, 
                    u8(recast.RC_NULL_AREA), 1)
                testing.expect(t, ok, "Adding tall obstacle should succeed")
            } else if x >= 4 && x <= 6 && z >= 4 && z <= 6 {
                // Medium height platform in center
                platform_min := ground_max
                platform_max := u16(8) // 4 units high
                ok = recast.rc_add_span(hf, x, z, platform_min, platform_max, 
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
    
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)
    
    ok := recast.rc_create_heightfield(hf, field_size, field_size, bmin, bmax, cell_size, cell_height)
    testing.expect(t, ok, "Heightfield creation should succeed")
    
    // Create a cliff-like structure
    cliff_x := i32(10)
    low_height := u16(4)  // 1 unit
    high_height := u16(40) // 10 units
    
    for z in 0..<field_size {
        for x in 0..<field_size {
            if x < cliff_x {
                // Low area
                ok = recast.rc_add_span(hf, x, z, 0, low_height, 
                    u8(recast.RC_WALKABLE_AREA), 1)
            } else {
                // High area (cliff)
                ok = recast.rc_add_span(hf, x, z, 0, high_height, 
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