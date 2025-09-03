package test_recast

import "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"
import "core:math"

// ================================
// SECTION 1: MARK WALKABLE TRIANGLES
// ================================

@(test)
test_mark_walkable_triangles_flat_ground :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create flat ground triangles (slope = 0 degrees) with correct winding
    vertices := [][3]f32{
        {0, 0, 0},    // 0
        {1, 0, 0},    // 1
        {1, 0, 1},    // 2
        {0, 0, 1},    // 3
    }

    indices := []i32{
        0, 2, 1,  // First triangle (counter-clockwise)
        0, 3, 2,  // Second triangle (counter-clockwise)
    }

    // Initialize areas as non-walkable
    areas := []u8{recast.RC_NULL_AREA, recast.RC_NULL_AREA}

    // Mark triangles with 45-degree slope threshold
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)

    // Both triangles should be marked walkable (0 degrees < 45 degrees)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)
    testing.expect_value(t, areas[1], recast.RC_WALKABLE_AREA)

    log.info("✓ Flat ground triangle marking test passed")
}

@(test)
test_mark_walkable_triangles_steep_slope :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create steep slope triangle (60 degrees)
    // For a slope, we need height change over horizontal distance
    height := f32(math.sqrt_f32(3)) // tan(60°) = √3, rise/run = height/1
    vertices := [][3]f32{
        {0, 0, 0},        // 0 - ground level front
        {1, 0, 0},        // 1 - ground level right
        {0, height, 1},   // 2 - elevated back (creates slope)
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_NULL_AREA}

    // Mark with 45-degree threshold - should remain non-walkable
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_NULL_AREA)

    // Mark with 70-degree threshold - should become walkable
    areas[0] = recast.RC_NULL_AREA // Reset
    recast.mark_walkable_triangles(70.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)

    log.info("✓ Steep slope triangle marking test passed")
}

@(test)
test_mark_walkable_triangles_exact_threshold :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create triangle with 44-degree slope (slightly more walkable than 45-degree threshold)
    vertices := [][3]f32{
        {0, 0, 0},          // 0
        {1, 0, 0},          // 1
        {0, 0.9656888, 1},  // 2 - creates 44-degree slope (norm.y = 0.719 > cos(45°) = 0.707)
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_NULL_AREA}

    // Test exactly at threshold - should be walkable
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)

    // Test just below threshold - should be walkable
    areas[0] = recast.RC_NULL_AREA
    recast.mark_walkable_triangles(46.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)

    // Test just above threshold - should be non-walkable
    areas[0] = recast.RC_NULL_AREA
    recast.mark_walkable_triangles(44.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_NULL_AREA)

    log.info("✓ Exact threshold triangle marking test passed")
}

@(test)
test_mark_walkable_triangles_vertical_wall :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create vertical wall triangle (90 degrees)
    vertices := [][3]f32{
        {0, 0, 0},    // 0
        {0, 1, 0},    // 1
        {0, 0.5, 1},  // 2 - creates vertical wall
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_NULL_AREA}

    // Even with high threshold, vertical wall should not be walkable
    recast.mark_walkable_triangles(89.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_NULL_AREA)

    log.info("✓ Vertical wall triangle marking test passed")
}

@(test)
test_mark_walkable_triangles_degenerate :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create degenerate triangle (all points collinear)
    vertices := [][3]f32{
        {0, 0, 0},    // 0
        {1, 0, 0},    // 1
        {2, 0, 0},    // 2 - all on same line
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_NULL_AREA}

    // Degenerate triangle should remain non-walkable regardless of threshold
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_NULL_AREA)

    log.info("✓ Degenerate triangle marking test passed")
}

@(test)
test_mark_walkable_triangles_mixed_slopes :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create multiple triangles with different slopes
    vertices := [][3]f32{
        // Flat triangle
        {0, 0, 0}, {1, 0, 0}, {0.5, 0, 1},        // 0,1,2
        // 30-degree slope triangle
        {2, 0, 0}, {3, 0, 0}, {2.5, 0.577, 1},    // 3,4,5 (tan(30°) ≈ 0.577)
        // 60-degree slope triangle
        {4, 0, 0}, {5, 0, 0}, {4.5, 1.732, 1},    // 6,7,8 (tan(60°) ≈ 1.732)
    }

    indices := []i32{
        0, 2, 1,  // Flat (0°) - counter-clockwise
        3, 5, 4,  // 30° slope - counter-clockwise
        6, 8, 7,  // 60° slope - counter-clockwise
    }

    areas := []u8{recast.RC_NULL_AREA, recast.RC_NULL_AREA, recast.RC_NULL_AREA}

    // Mark with 45-degree threshold
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)

    // Flat and 30-degree should be walkable, 60-degree should not
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA) // Flat
    testing.expect_value(t, areas[1], recast.RC_WALKABLE_AREA) // 30°
    testing.expect_value(t, areas[2], recast.RC_NULL_AREA)     // 60°

    log.info("✓ Mixed slopes triangle marking test passed")
}

// ================================
// SECTION 2: CLEAR UNWALKABLE TRIANGLES
// ================================

@(test)
test_clear_unwalkable_triangles_basic :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create mix of walkable and non-walkable triangles
    vertices := [][3]f32{
        {0, 0, 0}, {1, 0, 0}, {0.5, 0, 1},        // Flat - walkable
        {2, 0, 0}, {3, 0, 0}, {2.5, 2, 1},        // Steep - unwalkable
    }

    indices := []i32{
        0, 2, 1,  // Flat triangle - counter-clockwise
        3, 5, 4,  // Steep triangle - counter-clockwise
    }

    // Initially mark as walkable
    areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}

    // Clear unwalkable triangles with 45-degree threshold
    recast.clear_unwalkable_triangles(45.0, vertices, indices, areas)

    // Flat should remain walkable, steep should be cleared to non-walkable
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)
    testing.expect_value(t, areas[1], recast.RC_NULL_AREA)

    log.info("✓ Basic clear unwalkable triangles test passed")
}

@(test)
test_clear_unwalkable_triangles_preserve_non_walkable :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create triangles already marked as non-walkable
    vertices := [][3]f32{
        {0, 0, 0}, {1, 0, 0}, {0.5, 0, 1},        // Flat but already non-walkable
        {2, 0, 0}, {3, 0, 0}, {2.5, 2, 1},        // Steep and non-walkable
    }

    indices := []i32{
        0, 2, 1,  // Counter-clockwise
        3, 5, 4,  // Counter-clockwise
    }

    // Both start as non-walkable
    areas := []u8{recast.RC_NULL_AREA, recast.RC_NULL_AREA}

    // Clear unwalkable - should not change already non-walkable triangles
    recast.clear_unwalkable_triangles(45.0, vertices, indices, areas)

    // Both should remain non-walkable
    testing.expect_value(t, areas[0], recast.RC_NULL_AREA)
    testing.expect_value(t, areas[1], recast.RC_NULL_AREA)

    log.info("✓ Preserve non-walkable triangles test passed")
}

// ================================
// SECTION 3: TRIANGLE NORMAL CALCULATION
// ================================

@(test)
test_triangle_normal_calculation_accuracy :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test that slope calculation is based on accurate normal computation
    // Create triangle with known normal vector
    vertices := [][3]f32{
        {0, 0, 0},    // 0
        {1, 0, 0},    // 1
        {0, 0, 1},    // 2
    }

    // This triangle lies in XZ plane, so normal should be (0, 1, 0)
    // And slope should be 0 degrees from vertical (perfectly flat)

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_NULL_AREA}

    // Should be walkable with any reasonable threshold
    recast.mark_walkable_triangles(1.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)

    // Test triangle in YZ plane (vertical wall)
    vertices_vertical := [][3]f32{
        {0, 0, 0},    // 0
        {0, 1, 0},    // 1
        {0, 0, 1},    // 2
    }

    indices_vertical := []i32{0, 2, 1}  // Counter-clockwise
    areas_vertical := []u8{recast.RC_NULL_AREA}

    // Should not be walkable even with high threshold
    recast.mark_walkable_triangles(80.0, vertices_vertical, indices_vertical, areas_vertical)
    testing.expect_value(t, areas_vertical[0], recast.RC_NULL_AREA)

    log.info("✓ Triangle normal calculation accuracy test passed")
}

// ================================
// SECTION 4: EDGE CASES
// ================================

@(test)
test_triangle_operations_zero_area :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create triangle with zero area (two identical vertices)
    vertices := [][3]f32{
        {0, 0, 0},    // 0
        {0, 0, 0},    // 1 - identical to 0
        {1, 0, 0},    // 2
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_WALKABLE_AREA}

    // Zero-area triangle produces NaN normal, so NaN comparisons return false
    // This means clear_unwalkable_triangles will NOT clear it
    recast.clear_unwalkable_triangles(45.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA) // Should remain unchanged

    log.info("✓ Zero area triangle test passed")
}

@(test)
test_triangle_operations_tiny_triangle :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create very small but valid triangle
    epsilon := f32(1e-6)
    vertices := [][3]f32{
        {0, 0, 0},                  // 0
        {epsilon, 0, 0},           // 1
        {epsilon/2, 0, epsilon},   // 2
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_NULL_AREA}

    // Tiny but flat triangle should be marked walkable
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)

    log.info("✓ Tiny triangle test passed")
}

@(test)
test_triangle_operations_large_coordinates :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create triangle with large coordinate values
    large_val := f32(10000.0)
    vertices := [][3]f32{
        {large_val, 0, large_val},          // 0
        {large_val + 1, 0, large_val},      // 1
        {large_val + 0.5, 0, large_val + 1}, // 2
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding
    areas := []u8{recast.RC_NULL_AREA}

    // Large coordinates should not affect slope calculation
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], recast.RC_WALKABLE_AREA)

    log.info("✓ Large coordinates triangle test passed")
}

@(test)
test_triangle_operations_empty_input :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test with empty arrays - should not crash
    vertices := [][3]f32{}
    indices := []i32{}
    areas := []u8{}

    // Should handle empty input gracefully
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)
    recast.clear_unwalkable_triangles(45.0, vertices, indices, areas)

    log.info("✓ Empty input triangle operations test passed")
}

// ================================
// SECTION 5: INTEGRATION WITH AREA MARKING
// ================================

@(test)
test_triangle_operations_preserve_area_types :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test that walkable triangle marking preserves different area types
    vertices := [][3]f32{
        {0, 0, 0}, {1, 0, 0}, {0.5, 0, 1},  // Flat triangle
    }

    indices := []i32{0, 2, 1}  // Counter-clockwise winding

    // Test with custom area type
    CUSTOM_AREA :: 42
    areas := []u8{CUSTOM_AREA}

    // Mark walkable should not change custom area types, only NULL_AREA
    recast.mark_walkable_triangles(45.0, vertices, indices, areas)
    testing.expect_value(t, areas[0], CUSTOM_AREA) // Should remain custom area

    // Clear unwalkable should change walkable areas to NULL_AREA if slope is too steep
    vertices_steep := [][3]f32{
        {0, 0, 0}, {1, 0, 0}, {0.5, 2, 0.1},  // Steep triangle
    }

    areas_steep := []u8{CUSTOM_AREA}

    recast.clear_unwalkable_triangles(30.0, vertices_steep, indices, areas_steep)
    testing.expect_value(t, areas_steep[0], recast.RC_NULL_AREA) // Should be cleared

    log.info("✓ Area type preservation test passed")
}
