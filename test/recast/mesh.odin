package test_recast

import "core:testing"
import "core:log"
import "core:time"
import "core:slice"
import "core:math"
import "../../mjolnir/navigation/recast"
import "../../mjolnir/geometry"

@(test)
test_mesh_vertex_hash :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test vertex hashing function
    h1 := recast.vertex_hash(0, 0, 0)
    h2 := recast.vertex_hash(1, 1, 1)
    h3 := recast.vertex_hash(0, 0, 0) // Same as h1

    testing.expect(t, h1 == h3, "Same vertices should have same hash")
    testing.expect(t, h1 != h2, "Different vertices should have different hash (usually)")

    // Hash should be within bucket range
    testing.expect(t, h1 < recast.RC_VERTEX_BUCKET_COUNT, "Hash should be within bucket range")
    testing.expect(t, h2 < recast.RC_VERTEX_BUCKET_COUNT, "Hash should be within bucket range")
}

@(test)
test_add_vertex :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    verts := make([dynamic]recast.Mesh_Vertex)
    defer delete(verts)

    buckets := make([]recast.Vertex_Bucket, recast.RC_VERTEX_BUCKET_COUNT)
    defer delete(buckets)
    for &bucket in buckets {
        bucket.first = -1
    }

    // Add first vertex
    idx1 := recast.add_vertex(10, 20, 30, &verts, buckets)
    testing.expect(t, idx1 == 0, "First vertex should have index 0")
    testing.expect(t, len(verts) == 1, "Should have 1 vertex")

    // Add same vertex - should get same index
    idx2 := recast.add_vertex(10, 20, 30, &verts, buckets)
    testing.expect(t, idx2 == 0, "Same vertex should return same index")
    testing.expect(t, len(verts) == 1, "Should still have 1 vertex")

    // Add different vertex
    idx3 := recast.add_vertex(40, 50, 60, &verts, buckets)
    testing.expect(t, idx3 == 1, "Different vertex should have index 1")
    testing.expect(t, len(verts) == 2, "Should have 2 vertices")

    // Verify vertex data
    testing.expect(t, verts[0].x == 10 && verts[0].y == 20 && verts[0].z == 30, "First vertex data correct")
    testing.expect(t, verts[1].x == 40 && verts[1].y == 50 && verts[1].z == 60, "Second vertex data correct")
}

@(test)
test_triangulate_polygon :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test triangulation of a simple quad
    verts := make([][3]u16, 4)
    defer delete(verts)

    // Define a simple quad
    verts[0] = {0, 0, 0}    // Vertex 0
    verts[1] = {10, 0, 0}   // Vertex 1
    verts[2] = {10, 0, 10}  // Vertex 2
    verts[3] = {0, 0, 10}   // Vertex 3

    // Use clockwise winding as expected by Recast algorithm
    indices := []i32{0, 3, 2, 1}
    triangles := make([dynamic]i32)
    defer delete(triangles)

    result := recast.triangulate_polygon_u16(verts, indices, &triangles)
    testing.expect(t, result, "Triangulation should succeed")
    testing.expect(t, len(triangles) == 6, "Quad should produce 2 triangles (6 indices)")

    // Check that all triangle indices are valid
    all_valid := slice.all_of_proc(triangles[:], proc(idx: i32) -> bool {
        return idx >= 0 && idx < 4
    })
    testing.expect(t, all_valid, "All triangle indices should be valid (0-3)")
}

@(test)
test_triangulate_concave_polygon :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test triangulation of a concave L-shaped polygon
    verts := make([][3]u16, 6)
    defer delete(verts)

    // Define L-shaped polygon vertices (concave)
    verts[0] = {0, 0, 0}     // 0: Bottom-left
    verts[1] = {20, 0, 0}    // 1: Bottom-right
    verts[2] = {20, 0, 10}   // 2: Mid-right
    verts[3] = {10, 0, 10}   // 3: Mid-top
    verts[4] = {10, 0, 20}   // 4: Top-right
    verts[5] = {0, 0, 20}    // 5: Top-left

    // Use clockwise winding for L-shaped polygon
    indices := []i32{0, 5, 4, 3, 2, 1}
    triangles := make([dynamic]i32)
    defer delete(triangles)

    result := recast.triangulate_polygon_u16(verts, indices, &triangles)
    testing.expect(t, result, "Concave polygon triangulation should succeed")
    testing.expect(t, len(triangles) == 12, "6-vertex polygon should produce 4 triangles (12 indices)")

    // Check that all triangle indices are valid
    all_valid := slice.all_of_proc(triangles[:], proc(idx: i32) -> bool {
        return idx >= 0 && idx < 6
    })
    testing.expect(t, all_valid, "All triangle indices should be valid (0-5)")

    // Verify we have complete triangles
    testing.expect(t, len(triangles) % 3 == 0, "Should have complete triangles")

    log.infof("L-shaped polygon triangulated into %d triangles", len(triangles)/3)
}

@(test)
test_triangulate_star_polygon :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test triangulation of a star-shaped (highly concave) polygon
    verts := make([][3]u16, 8)
    defer delete(verts)

    // Define 4-pointed star polygon
    center_x, center_z := u16(50), u16(50)
    outer_radius, inner_radius := u16(40), u16(20)

    // Outer points: 0, 2, 4, 6
    // Inner points: 1, 3, 5, 7
    verts[0] = {center_x, 0, center_z - outer_radius}    // 0: Top
    verts[1] = {center_x + inner_radius, 0, center_z - inner_radius}  // 1: Top-right inner
    verts[2] = {center_x + outer_radius, 0, center_z}    // 2: Right
    verts[3] = {center_x + inner_radius, 0, center_z + inner_radius}  // 3: Bottom-right inner
    verts[4] = {center_x, 0, center_z + outer_radius}  // 4: Bottom
    verts[5] = {center_x - inner_radius, 0, center_z + inner_radius}  // 5: Bottom-left inner
    verts[6] = {center_x - outer_radius, 0, center_z}  // 6: Left
    verts[7] = {center_x - inner_radius, 0, center_z - inner_radius}  // 7: Top-left inner

    // Use clockwise winding for star polygon
    indices := []i32{0, 7, 6, 5, 4, 3, 2, 1}
    triangles := make([dynamic]i32)
    defer delete(triangles)

    result := recast.triangulate_polygon_u16(verts, indices, &triangles)
    testing.expect(t, result, "Star polygon triangulation should succeed")
    testing.expect(t, len(triangles) == 18, "8-vertex polygon should produce 6 triangles (18 indices)")

    // Check that all triangle indices are valid
    all_valid := slice.all_of_proc(triangles[:], proc(idx: i32) -> bool {
        return idx >= 0 && idx < 8
    })
    testing.expect(t, all_valid, "All triangle indices should be valid (0-7)")

    // Verify we have complete triangles
    testing.expect(t, len(triangles) % 3 == 0, "Should have complete triangles")

    log.infof("Star polygon triangulated into %d triangles", len(triangles)/3)
}

@(test)
test_geometric_primitives :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test geometric primitive functions - now using i32 vertices with 4 components
    verts := make([][4]i32, 4)  // 4 vertices * 4 components (x,y,z,pad)
    defer delete(verts)

    // Define a simple right triangle
    verts[0] = {0, 0, 0, 0}      // A: Origin
    verts[1] = {10, 0, 0, 0}     // B: Right
    verts[2] = {0, 0, 10, 0}     // C: Up
    verts[3] = {5, 0, 5, 0}      // D: Center

    // Test area2 function
    area_abc := geometry.area2(verts[0].xz, verts[1].xz, verts[2].xz)
    testing.expect(t, area_abc > 0, "Counter-clockwise triangle should have positive area")

    area_acb := geometry.area2(verts[0].xz, verts[2].xz, verts[1].xz)
    testing.expect(t, area_acb < 0, "Clockwise triangle should have negative area")
    testing.expect(t, area_abc == -area_acb, "Areas should be opposite")

    // Test left/right functions
    // In the XZ plane: A=(0,0), B=(10,0), C=(0,10)
    // C is to the RIGHT of line AB (positive area2), so left() should return false
    testing.expect(t, !geometry.left(verts[0].xz, verts[1].xz, verts[2].xz), "C should be right of AB (positive Z)")
    // B is to the LEFT of line AC (negative area2), so left() should return true
    testing.expect(t, geometry.left(verts[0].xz, verts[2].xz, verts[1].xz), "B should be left of AC")

    // Test collinear function
    // Add a point on the line AB
    verts[3] = {5, 0, 0, 0}  // D: On line AB
    // Collinear means area2 is 0
    testing.expect(t, geometry.area2(verts[0].xz, verts[1].xz, verts[3].xz) == 0, "Points A, B, D should be collinear")
    testing.expect(t, geometry.area2(verts[0].xz, verts[1].xz, verts[2].xz) != 0, "Points A, B, C should not be collinear")

    // Test between function
    testing.expect(t, geometry.between(verts[0].xz, verts[1].xz, verts[3].xz), "D should be between A and B")
    testing.expect(t, !geometry.between(verts[0].xz, verts[2].xz, verts[3].xz), "D should not be between A and C")
}

@(test)
test_degenerate_polygon_handling :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test handling of degenerate cases
    verts := make([][3]u16, 4)
    defer delete(verts)

    // Define a very thin polygon that might be challenging
    verts[0] = {0, 0, 0}      // A
    verts[1] = {100, 0, 0}    // B: Far right
    verts[2] = {100, 0, 1}    // C: Slightly up
    verts[3] = {0, 0, 1}      // D: Back to left

    // Use clockwise winding for degenerate polygon
    indices := []i32{0, 3, 2, 1}
    triangles := make([dynamic]i32)
    defer delete(triangles)

    result := recast.triangulate_polygon_u16(verts, indices, &triangles)
    testing.expect(t, result, "Degenerate polygon triangulation should succeed")
    testing.expect(t, len(triangles) > 0, "Should produce some triangles")
    testing.expect(t, len(triangles) % 3 == 0, "Should have complete triangles")

    // Check that all triangle indices are valid
    all_valid := slice.all_of_proc(triangles[:], proc(idx: i32) -> bool {
        return idx >= 0 && idx < 4
    })
    testing.expect(t, all_valid, "All triangle indices should be valid (0-3)")

    log.infof("Thin polygon triangulated into %d triangles", len(triangles)/3)
}

@(test)
test_validate_poly_mesh :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test with nil mesh
    testing.expect(t, !recast.validate_poly_mesh(nil), "Nil mesh should be invalid")

    // Create a valid simple mesh
    pmesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(pmesh)

    pmesh.npolys = 1
    pmesh.nvp = 3

    pmesh.verts = make([][3]u16, 3)    // 3 vertices * 3 components
    pmesh.polys = make([]u16, 6)    // 1 polygon * 3 verts * 2 (verts + neighbors)
    pmesh.regs = make([]u16, 1)
    pmesh.flags = make([]u16, 1)
    pmesh.areas = make([]u8, 1)

    // Set up triangle vertices
    pmesh.verts[0] = {0, 0, 0}
    pmesh.verts[1] = {10, 0, 0}
    pmesh.verts[2] = {5, 0, 10}

    // Set up triangle
    pmesh.polys[0], pmesh.polys[1], pmesh.polys[2] = 0, 1, 2
    pmesh.polys[3], pmesh.polys[4], pmesh.polys[5] = recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX

    testing.expect(t, recast.validate_poly_mesh(pmesh), "Valid mesh should pass validation")

    // Test invalid vertex reference
    pmesh.polys[0] = 10  // Invalid vertex index
    testing.expect(t, !recast.validate_poly_mesh(pmesh), "Invalid vertex reference should fail validation")
}

@(test)
test_build_simple_contour_mesh :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    // Create a simple contour set with one square contour
    cset := new(recast.Contour_Set)
    defer {
        if cset.conts != nil {
            // Clean up individual contour verts
            for i in 0..<len(cset.conts) {
                if cset.conts[i].verts != nil {
                    delete(cset.conts[i].verts)
                }
                if cset.conts[i].rverts != nil {
                    delete(cset.conts[i].rverts)
                }
            }
            delete(cset.conts)
        }
        free(cset)
    }

    cset.conts = make([dynamic]recast.Contour, 0)
    append(&cset.conts, recast.Contour{})
    cset.bmin = {0, 0, 0}
    cset.bmax = {10, 2, 10}
    cset.cs = 0.3
    cset.ch = 0.2
    cset.max_error = 1.3

    // Create a simple square contour (4 vertices)
    cont := &cset.conts[0]
    cont.verts = make([][4]i32, 4)  // 4 vertices
    cont.area = recast.RC_WALKABLE_AREA
    cont.reg = 1

    // Define square vertices (in contour coordinates) - counter-clockwise
    cont.verts[0] = {0, 5, 0, 0}    // Bottom-left
    cont.verts[1] = {0, 5, 10, 0}   // Top-left
    cont.verts[2] = {10, 5, 10, 0}  // Top-right
    cont.verts[3] = {10, 5, 0, 0}   // Bottom-right

    // Build polygon mesh
    pmesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(pmesh)

    result := recast.build_poly_mesh(cset, 6, pmesh)
    testing.expect(t, result, "Mesh building should succeed")
    testing.expect(t, len(pmesh.verts) > 0, "Should have vertices")
    testing.expect(t, pmesh.npolys > 0, "Should have polygons")
    testing.expect(t, pmesh.nvp == 6, "Max vertices per polygon should be set")

    // Validate final mesh
    testing.expect(t, recast.validate_poly_mesh(pmesh), "Generated mesh should be valid")

    log.infof("Generated mesh: %d vertices, %d polygons", len(pmesh.verts), pmesh.npolys)
}

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
