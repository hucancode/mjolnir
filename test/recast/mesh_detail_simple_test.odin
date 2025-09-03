package test_recast

import "core:testing"
import "core:log"
import "core:time"
import "core:math"
import "../../mjolnir/navigation/recast"

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
