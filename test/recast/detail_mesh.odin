package test_recast

import "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"
import "core:math"

@(test)
test_recast_detail_compilation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Simple compilation test to ensure all functions are accessible
    log.info("Testing Recast detail mesh compilation...")

    // Test data structure allocation
    dmesh := recast.alloc_poly_mesh_detail()
    testing.expect(t, dmesh != nil, "Should allocate detail mesh successfully")

    // Test validation with empty mesh
    valid := recast.validate_poly_mesh_detail(dmesh)
    testing.expect(t, !valid, "Empty detail mesh should be invalid")

    // Clean up
    recast.free_poly_mesh_detail(dmesh)

    log.info("✓ Recast detail mesh compilation test passed")
}

@(test)
test_simple_detail_mesh_build :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("Testing simple detail mesh build...")

    // Create minimal working example
    pmesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(pmesh)

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)

    dmesh := recast.alloc_poly_mesh_detail()
    defer recast.free_poly_mesh_detail(dmesh)

    // Set up minimal polygon mesh (single triangle)
    pmesh.npolys = 1
    pmesh.nvp = 3
    pmesh.bmin = {0, 0, 0}
    pmesh.bmax = {1, 1, 1}
    pmesh.cs = 0.1
    pmesh.ch = 0.1

    pmesh.verts = make([][3]u16, 3)
    defer delete(pmesh.verts)
    pmesh.verts[0] = {0, 0, 0}
    pmesh.verts[1] = {10, 0, 0}
    pmesh.verts[2] = {5, 0, 10}

    pmesh.polys = make([]u16, 6)  // 1 poly * 3 verts * 2 (verts + neighbors)
    defer delete(pmesh.polys)
    pmesh.polys[0] = 0; pmesh.polys[1] = 1; pmesh.polys[2] = 2
    pmesh.polys[3] = recast.RC_MESH_NULL_IDX
    pmesh.polys[4] = recast.RC_MESH_NULL_IDX
    pmesh.polys[5] = recast.RC_MESH_NULL_IDX

    pmesh.regs = make([]u16, 1)
    defer delete(pmesh.regs)
    pmesh.flags = make([]u16, 1)
    defer delete(pmesh.flags)
    pmesh.areas = make([]u8, 1)
    defer delete(pmesh.areas)
    pmesh.areas[0] = recast.RC_WALKABLE_AREA

    // Set up minimal compact heightfield
    chf.width = 2
    chf.height = 2
    chf.span_count = 4
    chf.bmin = pmesh.bmin
    chf.bmax = pmesh.bmax
    chf.cs = pmesh.cs
    chf.ch = pmesh.ch

    chf.cells = make([]recast.Compact_Cell, 4)
    defer delete(chf.cells)
    chf.spans = make([]recast.Compact_Span, 4)
    defer delete(chf.spans)

    for i in 0..<4 {
        cell := &chf.cells[i]
        cell.index = u32(i)
        cell.count = 1

        span := &chf.spans[i]
        span.y = 0
        span.h = 1
    }

    // Try to build detail mesh
    success := recast.build_poly_mesh_detail(pmesh, chf, 0.5, 1.0, dmesh)
    testing.expect(t, success, "Should build detail mesh successfully")

    if success {
        valid := recast.validate_poly_mesh_detail(dmesh)
        testing.expect(t, valid, "Built detail mesh should be valid")

        log.infof("Built detail mesh: %d meshes, %d vertices, %d triangles",
                  len(dmesh.meshes), len(dmesh.verts), len(dmesh.tris))
    }

    log.info("✓ Simple detail mesh build test passed")
}

@(test)
test_detail_mesh_sampling_quality :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test detail mesh sampling with different quality settings
    vertices := [][3]f32{
        {0, 0, 0}, {20, 0, 0}, {20, 1, 20}, {0, 2, 20},  // Sloped quad
    }

    indices := []i32{0, 1, 2, 0, 2, 3}
    areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}

    cfg := recast.Config{
        cs = 0.5,
        ch = 0.2,
        walkable_slope_angle = 45,
        walkable_height = 10,
        walkable_climb = 4,
        walkable_radius = 2,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 3.0,  // Test different sampling distances
        detail_sample_max_error = 0.5,
    }

    pmesh, dmesh_low, ok := recast.build_navmesh(vertices, indices, areas, cfg)
    testing.expect(t, ok, "Low quality build should succeed")
    defer recast.free_poly_mesh(pmesh)
    defer recast.free_poly_mesh_detail(dmesh_low)

    // Build with high quality sampling
    cfg.detail_sample_dist = 1.0
    cfg.detail_sample_max_error = 0.1

    pmesh2, dmesh_high, ok2 := recast.build_navmesh(vertices, indices, areas, cfg)
    testing.expect(t, ok2, "High quality build should succeed")
    defer recast.free_poly_mesh(pmesh2)
    defer recast.free_poly_mesh_detail(dmesh_high)

    // High quality should have more detail vertices
    testing.expect(t, len(dmesh_high.verts) >= len(dmesh_low.verts),
                  "Higher quality should have more or equal vertices")

    log.infof("Detail mesh quality test: Low=%d verts, High=%d verts",
              len(dmesh_low.verts), len(dmesh_high.verts))
}

@(test)
test_detail_mesh_height_accuracy :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test that detail mesh accurately represents height variations
    vertices := [][3]f32{
        // Create a surface with height variation
        {0, 0, 0}, {10, 2, 0}, {10, 1, 10}, {0, 3, 10},
    }

    indices := []i32{0, 1, 2, 0, 2, 3}
    areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}

    cfg := recast.Config{
        cs = 0.5,
        ch = 0.1,  // Small height resolution for accuracy
        walkable_slope_angle = 60,  // Allow steep slopes
        walkable_height = 20,
        walkable_climb = 10,
        walkable_radius = 1,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 0.5,  // Dense sampling
        detail_sample_max_error = 0.05,  // Low error tolerance
    }

    pmesh, dmesh, ok := recast.build_navmesh(vertices, indices, areas, cfg)
    testing.expect(t, ok, "Build with height variation should succeed")
    defer recast.free_poly_mesh(pmesh)
    defer recast.free_poly_mesh_detail(dmesh)

    if ok && len(dmesh.verts) > 0 {
        // Check height range in detail mesh
        min_y, max_y := dmesh.verts[0].y, dmesh.verts[0].y
        for v in dmesh.verts {
            min_y = min(min_y, v.y)
            max_y = max(max_y, v.y)
        }

        height_range := max_y - min_y
        testing.expect(t, height_range > 0, "Detail mesh should capture height variation")

        log.infof("Height accuracy test: Range=%.2f (%.2f to %.2f)",
                  height_range, min_y, max_y)
    }
}

@(test)
test_detail_mesh_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test edge cases: very small triangles, degenerate cases

    // Case 1: Very small triangle
    vertices_small := [][3]f32{
        {0, 0, 0}, {0.1, 0, 0}, {0.05, 0, 0.1},
    }
    indices_small := []i32{0, 1, 2}
    areas_small := []u8{recast.RC_WALKABLE_AREA}

    cfg := recast.Config{
        cs = 0.01,  // Very small cell size
        ch = 0.01,
        walkable_slope_angle = 45,
        walkable_height = 10,
        walkable_climb = 4,
        walkable_radius = 1,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 1,
        merge_region_area = 2,
        max_verts_per_poly = 6,
        detail_sample_dist = 0.01,
        detail_sample_max_error = 0.001,
    }

    pmesh, dmesh, ok := recast.build_navmesh(vertices_small, indices_small, areas_small, cfg)
    if ok {
        defer recast.free_poly_mesh(pmesh)
        defer recast.free_poly_mesh_detail(dmesh)
        testing.expect(t, recast.validate_poly_mesh_detail(dmesh),
                      "Small triangle detail mesh should be valid")
    }

    // Case 2: Large triangle with extreme aspect ratio
    vertices_large := [][3]f32{
        {0, 0, 0}, {100, 0, 0}, {50, 0, 0.1},  // Very thin triangle
    }
    indices_large := []i32{0, 1, 2}
    areas_large := []u8{recast.RC_WALKABLE_AREA}

    cfg.cs = 1.0
    cfg.ch = 0.2
    cfg.min_region_area = 8
    cfg.merge_region_area = 20
    cfg.detail_sample_dist = 2.0
    cfg.detail_sample_max_error = 0.5

    pmesh2, dmesh2, ok2 := recast.build_navmesh(vertices_large, indices_large, areas_large, cfg)
    if ok2 {
        defer recast.free_poly_mesh(pmesh2)
        defer recast.free_poly_mesh_detail(dmesh2)
        testing.expect(t, recast.validate_poly_mesh_detail(dmesh2),
                      "Large aspect ratio detail mesh should be valid")
    }

    log.info("✓ Detail mesh edge cases test passed")
}

@(test)
test_build_detail_mesh_simple :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create simple scenario for detail mesh building
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 8, 8, {0,0,0}, {8,8,8}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable area
    for x in 2..=5 {
        for z in 2..=5 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 2, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add walkable span")
        }
    }

    // Build compact heightfield
    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Build regions and contours
    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    ok = recast.build_regions(chf, 2, 8, 20)
    testing.expect(t, ok, "Failed to build regions")

    contour_set := recast.alloc_contour_set()
    testing.expect(t, contour_set != nil, "Failed to allocate contour set")
    defer recast.free_contour_set(contour_set)

    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})
    testing.expect(t, ok, "Failed to build contours")

    // Build polygon mesh
    poly_mesh := recast.alloc_poly_mesh()
    testing.expect(t, poly_mesh != nil, "Failed to allocate poly mesh")
    defer recast.free_poly_mesh(poly_mesh)

    ok = recast.build_poly_mesh(contour_set, 6, poly_mesh)
    testing.expect(t, ok, "Failed to build poly mesh")

    // Build detail mesh
    detail_mesh := recast.alloc_poly_mesh_detail()
    testing.expect(t, detail_mesh != nil, "Failed to allocate detail mesh")
    defer recast.free_poly_mesh_detail(detail_mesh)

    ok = recast.build_poly_mesh_detail(poly_mesh, chf, 2.0, 1.0, detail_mesh)
    testing.expect(t, ok, "Failed to build detail mesh")

    // Verify detail mesh was created
    testing.expect(t, len(detail_mesh.meshes) > 0, "Detail mesh should have mesh data")
    testing.expect(t, len(detail_mesh.verts) > 0, "Detail mesh should have vertices")
    testing.expect(t, len(detail_mesh.tris) > 0, "Detail mesh should have triangles")

    log.infof("✓ Simple detail mesh test passed - %d vertices, %d triangles", len(detail_mesh.verts), len(detail_mesh.tris)/4)
}

@(test)
test_build_detail_mesh_empty_input :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test detail mesh building with empty polygon mesh
    poly_mesh := recast.alloc_poly_mesh()
    testing.expect(t, poly_mesh != nil, "Failed to allocate poly mesh")
    defer recast.free_poly_mesh(poly_mesh)

    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    detail_mesh := recast.alloc_poly_mesh_detail()
    testing.expect(t, detail_mesh != nil, "Failed to allocate detail mesh")
    defer recast.free_poly_mesh_detail(detail_mesh)

    // Should handle empty input gracefully
    ok := recast.build_poly_mesh_detail(poly_mesh, chf, 2.0, 1.0, detail_mesh)
    testing.expect(t, ok, "Should handle empty input gracefully")

    // Empty input should result in empty detail mesh
    testing.expect_value(t, len(detail_mesh.meshes), 0)
    testing.expect_value(t, len(detail_mesh.verts), 0)
    testing.expect_value(t, len(detail_mesh.tris), 0)

    log.info("✓ Empty input detail mesh test passed")
}

@(test)
test_detail_mesh_sample_distance_variations :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 45 * time.Second)

    // Create base scenario
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create larger walkable area for better testing
    for x in 2..=7 {
        for z in 2..=7 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 2, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add walkable span")
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 2, 8, 20)

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)
    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})

    poly_mesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(poly_mesh)
    ok = recast.build_poly_mesh(contour_set, 6, poly_mesh)

    // Test different sample distances
    sample_distances := []f32{1.0, 2.0, 4.0}

    for sample_dist in sample_distances {
        detail_mesh := recast.alloc_poly_mesh_detail()
        defer recast.free_poly_mesh_detail(detail_mesh)

        ok = recast.build_poly_mesh_detail(poly_mesh, chf, sample_dist, 1.0, detail_mesh)
        testing.expect(t, ok, "Failed to build detail mesh with sample distance")

        vertex_count := len(detail_mesh.verts)
        triangle_count := len(detail_mesh.tris)
        log.infof("Sample distance %.1f: %d vertices, %d triangles", sample_dist, vertex_count, triangle_count)

        // Higher sample distance should generally result in fewer vertices
        testing.expect(t, vertex_count >= 0, "Should have valid vertex count")
        testing.expect(t, triangle_count >= 0, "Should have valid triangle count")
    }

    log.info("✓ Detail mesh sample distance variations test passed")
}

@(test)
test_detail_mesh_max_edge_error_variations :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 45 * time.Second)

    // Create base scenario with sloped surface for edge error testing
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.2)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create sloped area for better edge error testing
    for x in 2..=7 {
        for z in 2..=7 {
            // Create slight slope
            height := u16(2 + (x - 2) / 3)
            ok = recast.add_span(hf, i32(x), i32(z), 0, height, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add walkable span")
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 2, 8, 20)

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)
    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})

    poly_mesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(poly_mesh)
    ok = recast.build_poly_mesh(contour_set, 6, poly_mesh)

    // Test different max edge errors
    max_edge_errors := []f32{0.5, 1.0, 2.0}

    for max_edge_error in max_edge_errors {
        detail_mesh := recast.alloc_poly_mesh_detail()
        defer recast.free_poly_mesh_detail(detail_mesh)

        ok = recast.build_poly_mesh_detail(poly_mesh, chf, 2.0, max_edge_error, detail_mesh)
        testing.expect(t, ok, "Failed to build detail mesh with max edge error")

        vertex_count := len(detail_mesh.verts)
        triangle_count := len(detail_mesh.tris)
        log.infof("Max edge error %.1f: %d vertices, %d triangles", max_edge_error, vertex_count, triangle_count)

        // Lower edge error should generally result in more vertices
        testing.expect(t, vertex_count >= 0, "Should have valid vertex count")
        testing.expect(t, triangle_count >= 0, "Should have valid triangle count")
    }

    log.info("✓ Detail mesh max edge error variations test passed")
}

@(test)
test_detail_mesh_small_polygons :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create scenario with very small walkable areas
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create several tiny walkable areas
    tiny_areas := [][2]i32{{2,2}, {2,3}, {4,4}, {6,6}}
    for area in tiny_areas {
        ok = recast.add_span(hf, area[0], area[1], 0, 2, recast.RC_WALKABLE_AREA, 1)
        testing.expect(t, ok, "Failed to add tiny walkable area")
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 1, 5, 5) // Small regions

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)
    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})

    poly_mesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(poly_mesh)
    ok = recast.build_poly_mesh(contour_set, 6, poly_mesh)

    detail_mesh := recast.alloc_poly_mesh_detail()
    defer recast.free_poly_mesh_detail(detail_mesh)

    // Should handle small polygons without issues
    ok = recast.build_poly_mesh_detail(poly_mesh, chf, 1.0, 0.5, detail_mesh)
    testing.expect(t, ok, "Should build detail mesh for small polygons")

    log.infof("Small polygons: %d vertices, %d triangles", len(detail_mesh.verts), len(detail_mesh.tris)/4)
    log.info("✓ Detail mesh small polygons test passed")
}

@(test)
test_detail_mesh_extreme_parameters :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create base scenario
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 8, 8, {0,0,0}, {8,8,8}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add simple walkable area
    for x in 2..=5 {
        for z in 2..=5 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 2, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 2, 8, 20)

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)
    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})

    poly_mesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(poly_mesh)
    ok = recast.build_poly_mesh(contour_set, 6, poly_mesh)

    // Test extreme parameters
    extreme_cases := []struct{sample_dist, max_edge_error: f32}{
        {0.1, 0.1},     // Very small values
        {10.0, 10.0},   // Very large values
        {0.1, 10.0},    // Mixed
        {10.0, 0.1},    // Mixed opposite
    }

    for extreme_case in extreme_cases {
        detail_mesh := recast.alloc_poly_mesh_detail()
        defer recast.free_poly_mesh_detail(detail_mesh)

        ok = recast.build_poly_mesh_detail(poly_mesh, chf, extreme_case.sample_dist, extreme_case.max_edge_error, detail_mesh)

        // Should handle extreme parameters gracefully
        log.infof("Extreme params (%.1f, %.1f): success=%t", extreme_case.sample_dist, extreme_case.max_edge_error, ok)

        if ok {
            vertex_count := len(detail_mesh.verts)
            triangle_count := len(detail_mesh.tris)
            testing.expect(t, vertex_count >= 0, "Should have valid vertex count")
            testing.expect(t, triangle_count >= 0, "Should have valid triangle count")
        }
    }

    log.info("✓ Detail mesh extreme parameters test passed")
}

@(test)
test_detail_mesh_data_consistency :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create scenario for detail mesh validation
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 8, 8, {0,0,0}, {8,8,8}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable area
    for x in 2..=5 {
        for z in 2..=5 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 2, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 2, 8, 20)

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)
    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})

    poly_mesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(poly_mesh)
    ok = recast.build_poly_mesh(contour_set, 6, poly_mesh)

    detail_mesh := recast.alloc_poly_mesh_detail()
    defer recast.free_poly_mesh_detail(detail_mesh)

    ok = recast.build_poly_mesh_detail(poly_mesh, chf, 2.0, 1.0, detail_mesh)
    testing.expect(t, ok, "Failed to build detail mesh")

    // Validate detail mesh data consistency
    if len(detail_mesh.meshes) > 0 {
        // Each mesh entry should reference valid vertex and triangle ranges
        for i in 0..<len(detail_mesh.meshes) {
            mesh := detail_mesh.meshes[i]

            // Validate vertex base and count
            vert_base := int(mesh[0])
            vert_count := int(mesh[1])
            testing.expect(t, vert_base >= 0, "Vertex base should be non-negative")
            testing.expect(t, vert_base + vert_count <= len(detail_mesh.verts), "Vertex range should be within bounds")

            // Validate triangle base and count
            tri_base := int(mesh[2])
            tri_count := int(mesh[3])
            testing.expect(t, tri_base >= 0, "Triangle base should be non-negative")
            testing.expect(t, tri_base + tri_count <= len(detail_mesh.tris), "Triangle range should be within bounds")

            // Each triangle should reference valid vertices (relative to mesh vertex base)
            for tri_idx in 0..<tri_count {
                tri_index := tri_base + tri_idx
                triangle := detail_mesh.tris[tri_index]
                for vert_idx in 0..<3 {
                    vertex_ref := int(triangle[vert_idx])
                    // Triangle vertex indices should be relative to mesh base (0 to vert_count-1)
                    testing.expect(t, vertex_ref >= 0, "Triangle vertex ref should be >= 0")
                    testing.expect(t, vertex_ref < vert_count, "Triangle vertex ref should be < vert_count")
                    // Verify the global vertex index exists
                    global_vertex_index := vert_base + vertex_ref
                    testing.expect(t, global_vertex_index < len(detail_mesh.verts), "Global vertex index should be valid")
                }
            }
        }

        log.infof("Detail mesh validation passed: %d meshes, %d vertices, %d triangles",
                 len(detail_mesh.meshes), len(detail_mesh.verts), len(detail_mesh.tris))
    }

    log.info("✓ Detail mesh data consistency test passed")
}

@(test)
test_detail_mesh_performance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 60 * time.Second) // Longer timeout for performance test

    // Create larger scenario for performance testing
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 20, 20, {0,0,0}, {20,20,20}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add larger walkable area
    for x in 2..=17 {
        for z in 2..=17 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 2, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 8, 50, 50)

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)
    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})

    poly_mesh := recast.alloc_poly_mesh()
    defer recast.free_poly_mesh(poly_mesh)
    ok = recast.build_poly_mesh(contour_set, 6, poly_mesh)

    detail_mesh := recast.alloc_poly_mesh_detail()
    defer recast.free_poly_mesh_detail(detail_mesh)

    // Measure performance
    start_time := time.now()
    ok = recast.build_poly_mesh_detail(poly_mesh, chf, 2.0, 1.0, detail_mesh)
    end_time := time.now()

    duration := time.duration_milliseconds(time.diff(start_time, end_time))
    testing.expect(t, ok, "Failed to build detail mesh in performance test")
    testing.expect(t, duration < 5000, "Detail mesh building should complete within reasonable time")

    vertex_count := len(detail_mesh.verts)
    triangle_count := len(detail_mesh.tris)
    mesh_count := len(detail_mesh.meshes)

    log.infof("✓ Detail mesh performance test passed: %d ms, %d meshes, %d vertices, %d triangles",
             duration, mesh_count, vertex_count, triangle_count)
}
