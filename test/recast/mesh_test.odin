package test_recast

import "core:testing"
import "core:log"
import "core:time"
import "core:slice"
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
test_mesh_copy :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create source mesh
    src := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(src)

    src.npolys = 1
    src.nvp = 3
    src.cs = 0.3
    src.ch = 0.2

    src.verts = make([][3]u16, 3)
    src.polys = make([]u16, 6)
    src.regs = make([]u16, 1)
    src.flags = make([]u16, 1)
    src.areas = make([]u8, 1)

    // Fill with test data
    for &v, i in src.verts {
        v = {u16(i), u16(i), u16(i)}
    }
    for i in 0..<6 {
        src.polys[i] = u16(i)
    }
    src.regs[0] = 42
    src.flags[0] = 1
    src.areas[0] = 63

    // Create destination mesh
    dst := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(dst)

    // Copy mesh
    result := recast.copy_poly_mesh(src, dst)
    testing.expect(t, result, "Mesh copy should succeed")

    // Verify copied data
    testing.expect(t, len(dst.verts) == len(src.verts), "Vertex count should match")
    testing.expect(t, dst.npolys == src.npolys, "Polygon count should match")
    testing.expect(t, dst.nvp == src.nvp, "Max vertices per polygon should match")
    testing.expect(t, dst.cs == src.cs, "Cell size should match")
    testing.expect(t, dst.ch == src.ch, "Cell height should match")

    // Verify array data
    for i in 0..<3 {
        testing.expect(t, dst.verts[i] == src.verts[i], "Vertex data should match")
    }
    for i in 0..<6 {
        testing.expect(t, dst.polys[i] == src.polys[i], "Polygon data should match")
    }
    testing.expect(t, dst.regs[0] == src.regs[0], "Region data should match")
    testing.expect(t, dst.flags[0] == src.flags[0], "Flag data should match")
    testing.expect(t, dst.areas[0] == src.areas[0], "Area data should match")
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
test_mesh_optimization :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create mesh with degeneracies
    pmesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(pmesh)

    pmesh.npolys = 3
    pmesh.nvp = 3

    pmesh.verts = make([][3]u16, 6)
    pmesh.polys = make([]u16, 18)  // 3 polygons * 3 verts * 2
    pmesh.regs = make([]u16, 3)
    pmesh.flags = make([]u16, 3)
    pmesh.areas = make([]u8, 3)

    // Set up vertices (including unused ones)
    pmesh.verts[0] = {0, 0, 0}
    pmesh.verts[1] = {10, 0, 0}
    pmesh.verts[2] = {5, 0, 10}
    pmesh.verts[3] = {20, 0, 0}  // Unused
    pmesh.verts[4] = {30, 0, 0} // Unused
    pmesh.verts[5] = {40, 0, 0} // Unused

    // Set up polygons (including degenerate ones)
    // Valid triangle
    pmesh.polys[0], pmesh.polys[1], pmesh.polys[2] = 0, 1, 2
    pmesh.polys[3], pmesh.polys[4], pmesh.polys[5] = recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX

    // Degenerate triangle (duplicate vertex)
    pmesh.polys[6], pmesh.polys[7], pmesh.polys[8] = 0, 0, 1
    pmesh.polys[9], pmesh.polys[10], pmesh.polys[11] = recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX

    // Triangle with only 2 vertices
    pmesh.polys[12], pmesh.polys[13], pmesh.polys[14] = 1, 2, recast.RC_MESH_NULL_IDX
    pmesh.polys[15], pmesh.polys[16], pmesh.polys[17] = recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX

    original_vert_count := len(pmesh.verts)
    original_poly_count := pmesh.npolys

    // Optimize mesh
    result := recast.optimize_poly_mesh(pmesh)
    testing.expect(t, result, "Mesh optimization should succeed")
    testing.expect(t, len(pmesh.verts) <= original_vert_count, "Should have same or fewer vertices")
    testing.expect(t, pmesh.npolys < original_poly_count, "Should have fewer polygons (degenerates removed)")

    // Validate optimized mesh
    testing.expect(t, recast.validate_poly_mesh(pmesh), "Optimized mesh should be valid")

    log.infof("Mesh optimization: %d->%d vertices, %d->%d polygons",
             original_vert_count, len(pmesh.verts), original_poly_count, pmesh.npolys)
}
