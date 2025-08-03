package test_recast

import "core:log"
import "core:testing"
import "core:time"
import "core:math"
import "core:fmt"
import nav_recast "../../mjolnir/navigation/recast"

// Test contour generation with simple heightfield
@(test)
test_contour_generation_simple :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a simple 5x5 heightfield with one region
    chf := nav_recast.rc_alloc_compact_heightfield()
    defer nav_recast.rc_free_compact_heightfield(chf)

    chf.width = 5
    chf.height = 5
    chf.span_count = 25
    chf.cs = 0.3
    chf.ch = 0.2
    chf.bmin = {0, 0, 0}
    chf.bmax = {1.5, 1.0, 1.5}

    // Allocate cells and spans
    chf.cells = make([]nav_recast.Rc_Compact_Cell, 25)
    chf.spans = make([]nav_recast.Rc_Compact_Span, 25)
    chf.areas = make([]u8, 25)

    // Create a simple square region in the center (3x3)
    span_idx := u32(0)
    for y in 0..<5 {
        for x in 0..<5 {
            cell_idx := x + y * 5
            chf.cells[cell_idx].index = span_idx
            chf.cells[cell_idx].count = 1

            // Set region for center 3x3 area
            if x >= 1 && x <= 3 && y >= 1 && y <= 3 {
                chf.spans[span_idx].reg = 1
                chf.areas[span_idx] = nav_recast.RC_WALKABLE_AREA
            } else {
                chf.spans[span_idx].reg = 0
                chf.areas[span_idx] = nav_recast.RC_NULL_AREA
            }

            chf.spans[span_idx].y = 10
            chf.spans[span_idx].h = 20

            // Set connections (4-connected)
            for dir in 0..<4 {
                nx := x + int(nav_recast.get_dir_offset_x(dir))
                ny := y + int(nav_recast.get_dir_offset_y(dir))

                if nx >= 0 && nx < 5 && ny >= 0 && ny < 5 {
                    nav_recast.rc_set_con(&chf.spans[span_idx], dir, 0)
                } else {
                    nav_recast.rc_set_con(&chf.spans[span_idx], dir, nav_recast.RC_NOT_CONNECTED)
                }
            }

            span_idx += 1
        }
    }

    // Build contours
    cset := nav_recast.rc_alloc_contour_set()
    defer nav_recast.rc_free_contour_set(cset)

    result := nav_recast.rc_build_contours(chf, 1.0, 10, cset)
    testing.expect(t, result, "Contour building should succeed")
    testing.expect(t, len(cset.conts) == 1, "Should have exactly one contour for the square region")

    if len(cset.conts) > 0 {
        cont := &cset.conts[0]
        testing.expect(t, len(cont.verts) >= 4, "Square contour should have at least 4 vertices")
        testing.expect(t, cont.reg == 1, "Contour should have correct region ID")
        testing.expect(t, cont.area == nav_recast.RC_WALKABLE_AREA, "Contour should have walkable area")

        log.infof("Generated contour with %d vertices for region %d", len(cont.verts), cont.reg)
    }
}

// Test contour generation with multiple regions
@(test)
test_contour_generation_multiple_regions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a 10x10 heightfield with two separate regions
    chf := nav_recast.rc_alloc_compact_heightfield()
    defer nav_recast.rc_free_compact_heightfield(chf)

    chf.width = 10
    chf.height = 10
    chf.span_count = 100
    chf.cs = 0.3
    chf.ch = 0.2
    chf.bmin = {0, 0, 0}
    chf.bmax = {3.0, 1.0, 3.0}

    // Allocate cells and spans
    chf.cells = make([]nav_recast.Rc_Compact_Cell, 100)
    chf.spans = make([]nav_recast.Rc_Compact_Span, 100)
    chf.areas = make([]u8, 100)

    // Create two separate square regions
    span_idx := u32(0)
    for y in 0..<10 {
        for x in 0..<10 {
            cell_idx := x + y * 10
            chf.cells[cell_idx].index = span_idx
            chf.cells[cell_idx].count = 1

            if x >= 1 && x <= 3 && y >= 1 && y <= 3 {
                // Region 1: top-left 3x3
                chf.spans[span_idx].reg = 1
                chf.areas[span_idx] = nav_recast.RC_WALKABLE_AREA
            } else if x >= 6 && x <= 8 && y >= 6 && y <= 8 {
                // Region 2: bottom-right 3x3
                chf.spans[span_idx].reg = 2
                chf.areas[span_idx] = nav_recast.RC_WALKABLE_AREA
            } else {
                chf.spans[span_idx].reg = 0
                chf.areas[span_idx] = nav_recast.RC_NULL_AREA
            }

            chf.spans[span_idx].y = 10
            chf.spans[span_idx].h = 20

            // Set connections
            for dir in 0..<4 {
                nx := x + int(nav_recast.get_dir_offset_x(dir))
                ny := y + int(nav_recast.get_dir_offset_y(dir))

                if nx >= 0 && nx < 10 && ny >= 0 && ny < 10 {
                    nav_recast.rc_set_con(&chf.spans[span_idx], dir, 0)
                } else {
                    nav_recast.rc_set_con(&chf.spans[span_idx], dir, nav_recast.RC_NOT_CONNECTED)
                }
            }

            span_idx += 1
        }
    }

    // Build contours
    cset := nav_recast.rc_alloc_contour_set()
    defer nav_recast.rc_free_contour_set(cset)

    result := nav_recast.rc_build_contours(chf, 1.0, 10, cset)
    testing.expect(t, result, "Contour building should succeed")
    testing.expect(t, len(cset.conts) == 2, "Should have exactly two contours for two regions")

    // Verify both contours
    region1_found, region2_found := false, false
    for i in 0..<len(cset.conts) {
        cont := &cset.conts[i]
        if cont.reg == 1 {
            region1_found = true
            testing.expect(t, len(cont.verts) >= 4, "Region 1 contour should have at least 4 vertices")
        } else if cont.reg == 2 {
            region2_found = true
            testing.expect(t, len(cont.verts) >= 4, "Region 2 contour should have at least 4 vertices")
        }
    }

    testing.expect(t, region1_found && region2_found, "Both regions should have contours")
    log.infof("Generated %d contours for multiple regions", len(cset.conts))
}

// Test triangulation with complex polygons
@(test)
test_triangulation_complex_polygon :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test with a more complex polygon (octagon)
    verts := make([][3]u16, 8)
    defer delete(verts)

    // Define octagon vertices
    center_x, center_z := u16(50), u16(50)
    radius := u16(30)

    for i in 0..<8 {
        angle := f32(i) * math.TAU / 8.0
        x := center_x + u16(f32(radius) * math.cos(angle))
        z := center_z + u16(f32(radius) * math.sin(angle))
        verts[i] = {x, 0, z}
    }

    // Create indices in clockwise order
    indices := []i32{0, 7, 6, 5, 4, 3, 2, 1}
    triangles := make([dynamic]i32)
    defer delete(triangles)

    result := nav_recast.triangulate_polygon(verts, indices, &triangles)
    testing.expect(t, result, "Octagon triangulation should succeed")
    testing.expect(t, len(triangles) == 18, "Octagon should produce 6 triangles (18 indices)")

    // Verify all triangles are valid
    for i := 0; i < len(triangles); i += 3 {
        v0, v1, v2 := triangles[i], triangles[i+1], triangles[i+2]
        testing.expect(t, v0 >= 0 && v0 < 8, "Triangle vertex 0 should be valid")
        testing.expect(t, v1 >= 0 && v1 < 8, "Triangle vertex 1 should be valid")
        testing.expect(t, v2 >= 0 && v2 < 8, "Triangle vertex 2 should be valid")
        testing.expect(t, v0 != v1 && v1 != v2 && v0 != v2, "Triangle vertices should be distinct")
    }

    log.infof("Octagon triangulated into %d triangles", len(triangles)/3)
}

// Test edge cases in triangulation
@(test)
test_triangulation_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test 1: Triangle (minimum polygon)
    {
        verts := [][3]u16{{0, 0, 0}, {10, 0, 0}, {5, 0, 10}}
        indices := []i32{0, 2, 1}
        triangles := make([dynamic]i32)
        defer delete(triangles)

        result := nav_recast.triangulate_polygon(verts, indices, &triangles)
        testing.expect(t, result, "Triangle triangulation should succeed")
        testing.expect(t, len(triangles) == 3, "Triangle should produce 1 triangle (3 indices)")
    }

    // Test 2: Degenerate case - less than 3 vertices
    {
        verts := [][3]u16{{0, 0, 0}, {10, 0, 0}}
        indices := []i32{0, 1}
        triangles := make([dynamic]i32)
        defer delete(triangles)

        result := nav_recast.triangulate_polygon(verts[:], indices, &triangles)
        testing.expect(t, !result, "Triangulation with 2 vertices should fail")
    }

    // Test 3: Self-intersecting polygon (bowtie)
    {
        verts := [][3]u16{{0, 0, 0}, {10, 0, 10}, {10, 0, 0}, {0, 0, 10}}
        indices := []i32{0, 1, 2, 3}
        triangles := make([dynamic]i32)
        defer delete(triangles)

        result := nav_recast.triangulate_polygon(verts[:], indices, &triangles)
        // Should either succeed with some triangulation or fail gracefully
        if result {
            testing.expect(t, len(triangles) > 0, "If successful, should produce triangles")
            testing.expect(t, len(triangles) % 3 == 0, "Should have complete triangles")
        }
        log.infof("Bowtie polygon triangulation result: %v", result)
    }
}

// Test contour simplification
@(test)
test_contour_simplification :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a contour with many collinear points
    raw_verts := make([dynamic][4]i32)
    defer delete(raw_verts)

    // Add points along a square with extra collinear points
    // Bottom edge with extra points
    append(&raw_verts, [4]i32{0, 10, 0, 0})
    append(&raw_verts, [4]i32{10, 10, 0, 0})  // Extra point
    append(&raw_verts, [4]i32{20, 10, 0, 0})  // Extra point
    append(&raw_verts, [4]i32{30, 10, 0, 0})

    // Right edge
    append(&raw_verts, [4]i32{30, 10, 10, 0})
    append(&raw_verts, [4]i32{30, 10, 20, 0}) // Extra point
    append(&raw_verts, [4]i32{30, 10, 30, 0})

    // Top edge
    append(&raw_verts, [4]i32{20, 10, 30, 0}) // Extra point
    append(&raw_verts, [4]i32{10, 10, 30, 0}) // Extra point
    append(&raw_verts, [4]i32{0, 10, 30, 0})

    // Left edge
    append(&raw_verts, [4]i32{0, 10, 20, 0})  // Extra point
    append(&raw_verts, [4]i32{0, 10, 10, 0})  // Extra point

    simplified := make([dynamic][4]i32)
    defer delete(simplified)

    // Simplify with reasonable error tolerance
    nav_recast.simplify_contour(raw_verts[:], &simplified, 1.0, 0.3)

    // Should have fewer vertices after simplification
    testing.expect(t, len(simplified) < len(raw_verts), "Simplification should reduce vertex count")
    testing.expect(t, len(simplified) >= 4, "Should have at least 4 vertices")

    log.infof("Contour simplified from %d to %d vertices",
              len(raw_verts), len(simplified))
}

// Test simple square first
@(test)
test_simple_square_mesh :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a contour set with a simple square
    cset := nav_recast.rc_alloc_contour_set()
    defer nav_recast.rc_free_contour_set(cset)

    // Set up contours with append instead
    cset.conts = make([dynamic]nav_recast.Rc_Contour, 0)
    append(&cset.conts, nav_recast.Rc_Contour{})
    cset.bmin = {0, 0, 0}
    cset.bmax = {30, 10, 30}
    cset.cs = 0.3
    cset.ch = 0.2

    // Create square contour
    cont := &cset.conts[0]
    cont.verts = make([][4]i32, 4)  // 4 vertices
    cont.area = nav_recast.RC_WALKABLE_AREA
    cont.reg = 1

    // Define square vertices (clockwise)
    cont.verts[0] = {0, 5, 0, 0}      // Bottom-left
    cont.verts[1] = {10, 5, 0, 0}     // Bottom-right
    cont.verts[2] = {10, 5, 10, 0}    // Top-right
    cont.verts[3] = {0, 5, 10, 0}     // Top-left

    // Build polygon mesh
    pmesh := nav_recast.rc_alloc_poly_mesh()
    defer nav_recast.rc_free_poly_mesh(pmesh)

    result := nav_recast.rc_build_poly_mesh(cset, 6, pmesh)
    testing.expect(t, result, "Mesh building from square contour should succeed")
    testing.expect(t, len(pmesh.verts) == 4, "Square should have exactly 4 vertices")
    testing.expect(t, pmesh.npolys >= 1, "Square should have at least 1 polygon")

    log.infof("Square contour converted to mesh: %d vertices, %d polygons",
              len(pmesh.verts), pmesh.npolys)
}

// Test simple L-shape
@(test)
test_simple_l_shape_mesh :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a contour set with a simple L-shape
    cset := nav_recast.rc_alloc_contour_set()
    defer nav_recast.rc_free_contour_set(cset)

    // Set up contours with append instead
    cset.conts = make([dynamic]nav_recast.Rc_Contour, 0)
    append(&cset.conts, nav_recast.Rc_Contour{})
    cset.bmin = {0, 0, 0}
    cset.bmax = {30, 10, 30}
    cset.cs = 1.0
    cset.ch = 1.0

    // Create L-shaped contour
    cont := &cset.conts[0]
    cont.verts = make([][4]i32, 6)  // 6 vertices
    cont.area = nav_recast.RC_WALKABLE_AREA
    cont.reg = 1

    // Define L-shape vertices (clockwise) - using integer coordinates
    cont.verts[0] = {0, 0, 0, 0}      // Bottom-left
    cont.verts[1] = {2, 0, 0, 0}      // Bottom-right
    cont.verts[2] = {2, 0, 1, 0}      // Mid-right
    cont.verts[3] = {1, 0, 1, 0}      // Mid-inner
    cont.verts[4] = {1, 0, 2, 0}      // Top-right
    cont.verts[5] = {0, 0, 2, 0}      // Top-left

    // Debug: Print input vertices
    log.info("L-shape input vertices:")
    for i in 0..<6 {
        v := cont.verts[i]
        log.infof("  v[%d] = (%d, %d, %d)", i, v[0], v[1], v[2])
    }

    // Build polygon mesh
    pmesh := nav_recast.rc_alloc_poly_mesh()
    defer nav_recast.rc_free_poly_mesh(pmesh)

    result := nav_recast.rc_build_poly_mesh(cset, 6, pmesh)
    testing.expect(t, result, "Mesh building from L-shaped contour should succeed")
    testing.expect(t, len(pmesh.verts) == 6, "L-shape should have exactly 6 vertices")
    testing.expect(t, pmesh.npolys >= 2, "L-shape should have at least 2 polygons")

    log.infof("L-shaped contour converted to mesh: %d vertices, %d polygons",
              len(pmesh.verts), pmesh.npolys)
}

// Integration test: contour to mesh pipeline
@(test)
test_contour_to_mesh_pipeline :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a contour set with an L-shaped region
    cset := nav_recast.rc_alloc_contour_set()
    defer nav_recast.rc_free_contour_set(cset)

    // Set up contours with append instead
    cset.conts = make([dynamic]nav_recast.Rc_Contour, 0)
    append(&cset.conts, nav_recast.Rc_Contour{})
    cset.bmin = {0, 0, 0}
    cset.bmax = {30, 10, 30}
    cset.cs = 0.3
    cset.ch = 0.2

    // Create L-shaped contour
    cont := &cset.conts[0]
    cont.verts = make([][4]i32, 6)  // 6 vertices
    cont.area = nav_recast.RC_WALKABLE_AREA
    cont.reg = 1

    // Define L-shape vertices (clockwise)
    cont.verts[0] = {0, 5, 0, 0}      // Bottom-left
    cont.verts[1] = {20, 5, 0, 0}     // Bottom-right
    cont.verts[2] = {20, 5, 10, 0}    // Mid-right
    cont.verts[3] = {10, 5, 10, 0}    // Mid-inner
    cont.verts[4] = {10, 5, 20, 0}    // Top-right
    cont.verts[5] = {0, 5, 20, 0}     // Top-left

    // Debug: Print input contour vertices
    log.info("Input contour vertices:")
    for i in 0..<6 {
        v := cont.verts[i]
        log.infof("  cont v[%d] = (%d, %d, %d)", i, v[0], v[1], v[2])
    }

    // Build polygon mesh
    pmesh := nav_recast.rc_alloc_poly_mesh()
    defer nav_recast.rc_free_poly_mesh(pmesh)

    result := nav_recast.rc_build_poly_mesh(cset, 6, pmesh)
    testing.expect(t, result, "Mesh building from L-shaped contour should succeed")
    testing.expect(t, len(pmesh.verts) >= 6, "Should have at least 6 vertices")
    testing.expect(t, pmesh.npolys >= 1, "Should have at least 1 polygon")

    // Debug: Print mesh vertices
    log.infof("Mesh has %d vertices:", len(pmesh.verts))
    for i in 0..<len(pmesh.verts) {
        v := pmesh.verts[i]
        log.infof("  mesh v[%d] = (%d, %d, %d)", i, v[0], v[1], v[2])
    }

    // Debug: Print mesh polygons
    log.infof("Mesh has %d polygons:", pmesh.npolys)
    for i in 0..<pmesh.npolys {
        poly_idx := int(i) * int(pmesh.nvp) * 2
        log.infof("  poly[%d]:", i)

        // Count and print vertices
        vert_count := 0
        verts_str := "    vertices: "
        for j in 0..<pmesh.nvp {
            if pmesh.polys[poly_idx + int(j)] != nav_recast.RC_MESH_NULL_IDX {
                verts_str = fmt.aprintf("%s%d ", verts_str, pmesh.polys[poly_idx + int(j)])
                vert_count += 1
            }
        }
        log.infof("%s(count=%d)", verts_str, vert_count)

        // Print area and region
        log.infof("    area=%d, reg=%d", pmesh.areas[i], pmesh.regs[i])
    }

    // Validate the mesh
    testing.expect(t, nav_recast.validate_poly_mesh(pmesh), "Generated mesh should be valid")

    // Check that polygons cover the L-shape properly
    total_poly_verts := 0
    unique_verts := make(map[u16]bool)
    defer delete(unique_verts)

    for i in 0..<pmesh.npolys {
        poly_idx := int(i) * int(pmesh.nvp) * 2
        for j in 0..<pmesh.nvp {
            if pmesh.polys[poly_idx + int(j)] != nav_recast.RC_MESH_NULL_IDX {
                total_poly_verts += 1
                unique_verts[pmesh.polys[poly_idx + int(j)]] = true
            }
        }
    }

    log.infof("Total vertex references: %d, Unique vertices used: %d", total_poly_verts, len(unique_verts))
    testing.expect(t, total_poly_verts >= 6, "Polygons should use at least 6 vertices total")
    testing.expect(t, len(unique_verts) >= 6, "Should use at least 6 unique vertices")

    log.infof("L-shaped contour converted to mesh: %d vertices, %d polygons",
              len(pmesh.verts), pmesh.npolys)
}
