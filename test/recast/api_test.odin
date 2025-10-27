package test_recast

import "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"
import "core:fmt"

// Test high-level API functions
@(test)
test_api_simple_build :: proc(t: ^testing.T) {
        // Simple square floor geometry
    vertices := [][3]f32{
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        {0, 0, 10},
    }
    indices := []i32{
        0, 1, 2,
        0, 2, 3,
    }
    areas := []u8{
        recast.RC_WALKABLE_AREA,
        recast.RC_WALKABLE_AREA,
    }
    // Test configuration
    config := recast.Config{
        cs = 0.3,
        ch = 0.2,
        walkable_slope_angle = 45,
        walkable_height = 2,
        walkable_climb = 1,
        walkable_radius = 1,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 6,
        detail_sample_max_error = 1,
    }
    // Test main build function
    pmesh, dmesh, ok := recast.build_navmesh(vertices, indices, areas, config)
    testing.expect(t, ok, "Build failed")
    testing.expect(t, pmesh != nil, "No polygon mesh generated")
    testing.expect(t, dmesh != nil, "No detail mesh generated")
    defer recast.free_poly_mesh(pmesh)
    defer recast.free_poly_mesh_detail(dmesh)
    // Check generated mesh
    testing.expect(t, len(pmesh.verts) > 0, "No vertices generated")
    testing.expect(t, pmesh.npolys > 0, "No polygons generated")
    log.infof("API Simple Build Test: Generated %d polygons, %d vertices",
              pmesh.npolys, len(pmesh.verts))
}

@(test)
test_api_quick_build :: proc(t: ^testing.T) {
        // Test the convenience quick build function
    vertices := [][3]f32{
        {0, 0, 0},
        {20, 0, 0},
        {20, 0, 20},
        {0, 0, 20},
    }
    indices := []i32{
        0, 1, 2,
        0, 2, 3,
    }
    // Create areas array
    areas := make([]u8, len(indices)/3)
    defer delete(areas)
    for i in 0..<len(areas) {
        areas[i] = recast.RC_WALKABLE_AREA
    }
    // Create config
    cfg := recast.Config{
        cs = 0.5,
        ch = 0.5,
        walkable_slope_angle = 45,
        walkable_height = 2,
        walkable_climb = 1,
        walkable_radius = 1,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 6,
        detail_sample_max_error = 1,
    }
    pmesh, dmesh, ok := recast.build_navmesh(vertices, indices, areas, cfg)
    testing.expect(t, ok, "Quick build failed")
    testing.expect(t, pmesh != nil, "No polygon mesh from quick build")
    testing.expect(t, dmesh != nil, "No detail mesh from quick build")
    defer {
        recast.free_poly_mesh(pmesh)
        recast.free_poly_mesh_detail(dmesh)
    }
    // Check result
    testing.expect(t, len(pmesh.verts) > 0, "Quick build generated no vertices")
    testing.expect(t, pmesh.npolys > 0, "Quick build generated no polygons")
    log.infof("API Quick Build Test: Generated %d polygons with cell size 0.5",
              pmesh.npolys)
}

@(test)
test_api_configuration :: proc(t: ^testing.T) {
        // Test that different configurations produce valid results
    vertices := [][3]f32{
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        {0, 0, 10},
    }
    indices := []i32{
        0, 1, 2,
        0, 2, 3,
    }
    areas := []u8{
        recast.RC_WALKABLE_AREA,
        recast.RC_WALKABLE_AREA,
    }
    configs := []struct{name: string, cs: f32, ch: f32}{
        {"Fast", 0.5, 0.5},
        {"Balanced", 0.3, 0.2},
        {"High_Quality", 0.1, 0.1},
    }
    for cfg in configs {
        config := recast.Config{
            cs = cfg.cs,
            ch = cfg.ch,
            walkable_slope_angle = 45,
            walkable_height = 2,
            walkable_climb = 1,
            walkable_radius = 1,
            max_edge_len = 12,
            max_simplification_error = 1.3,
            min_region_area = 8,
            merge_region_area = 20,
            max_verts_per_poly = 6,
            detail_sample_dist = 6,
            detail_sample_max_error = 1,
        }
        // Test that configuration produces valid navmesh
        pmesh, dmesh, ok := recast.build_navmesh(vertices, indices, areas, config)
        testing.expect(t, ok, "Configuration should produce valid navmesh")
        testing.expect(t, pmesh != nil, "Should generate polygon mesh")
        testing.expect(t, dmesh != nil, "Should generate detail mesh")
        if pmesh != nil {
            testing.expect(t, pmesh.npolys > 0, "Should generate at least one polygon")
            testing.expect(t, len(pmesh.verts) > 0, "Should generate vertices")
        }
        recast.free_poly_mesh(pmesh)
        recast.free_poly_mesh_detail(dmesh)
        log.infof("Config %s: cs=%.2f, ch=%.2f -> %d polygons",
                  cfg.name, config.cs, config.ch, pmesh != nil ? pmesh.npolys : 0)
    }
}

@(test)
test_api_error_handling :: proc(t: ^testing.T) {
        // Test error handling with invalid inputs
    // Empty geometry
    empty_vertices := [][3]f32{}
    empty_indices := []i32{}
    empty_areas := []u8{}
    config := recast.Config{
        cs = 0.3,
        ch = 0.2,
        walkable_slope_angle = 45,
        walkable_height = 2,
        walkable_climb = 1,
        walkable_radius = 1,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 6,
        detail_sample_max_error = 1,
    }
    pmesh, dmesh, ok := recast.build_navmesh(empty_vertices, empty_indices, empty_areas, config)
    testing.expect(t, !ok, "Should fail with empty geometry")
    testing.expect(t, pmesh == nil, "Should not create polygon mesh on failure")
    testing.expect(t, dmesh == nil, "Should not create detail mesh on failure")
    // Invalid configuration
    bad_config := config
    bad_config.cs = -1.0  // Invalid cell size
    good_vertices := [][3]f32{{0, 0, 0}, {10, 0, 0}, {10, 0, 10}, {0, 0, 10}}
    good_indices := []i32{0, 1, 2, 0, 2, 3}
    good_areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}
    // Build with invalid config should fail
    pmesh2, dmesh2, ok2 := recast.build_navmesh(good_vertices, good_indices, good_areas, bad_config)
    testing.expect(t, !ok2, "Build should fail with invalid config")
    testing.expect(t, pmesh2 == nil, "Should not create polygon mesh on failure")
    testing.expect(t, dmesh2 == nil, "Should not create detail mesh on failure")
    log.infof("API Error Handling Test: Correctly handled invalid inputs")
}

@(test)
test_api_build_with_areas :: proc(t: ^testing.T) {
        // Test building with custom area types
    vertices := [][3]f32{
        {0, 0, 0},
        {40, 0, 0},
        {40, 0, 40},
        {0, 0, 40},
        // Another section
        {50, 0, 0},
        {90, 0, 0},
        {90, 0, 40},
        {50, 0, 40},
    }
    indices := []i32{
        0, 1, 2,    // First area
        0, 2, 3,
        4, 5, 6,    // Second area
        4, 6, 7,
    }
    areas := []u8{
        recast.RC_WALKABLE_AREA,  // Regular walkable
        recast.RC_WALKABLE_AREA,
        10,                         // Custom area type
        10,
    }
    config := recast.Config{
        cs = 0.3,
        ch = 0.2,
        walkable_slope_angle = 45,
        walkable_height = 2,
        walkable_climb = 1,
        walkable_radius = 1,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 6,
        detail_sample_max_error = 1,
    }
    pmesh, dmesh, ok := recast.build_navmesh(vertices, indices, areas, config)
    testing.expect(t, ok, "Build with areas failed")
    testing.expect(t, pmesh != nil, "No polygon mesh generated")
    defer recast.free_poly_mesh(pmesh)
    defer recast.free_poly_mesh_detail(dmesh)
    // Check that different areas were preserved
    area_counts := map[u8]int{}
    defer delete(area_counts)
    for i in 0..<pmesh.npolys {
        area := pmesh.areas[i]
        area_counts[area] = area_counts[area] + 1
    }
    testing.expect(t, len(area_counts) > 1, "Should have multiple area types")
    log.infof("API Build with Areas Test: Generated %d area types", len(area_counts))
}

@(test)
test_api_comprehensive_pipeline :: proc(t: ^testing.T) {
        // Test complex geometry generation and navigation mesh building
    vertices := make([dynamic][3]f32)
    indices := make([dynamic]i32)
    areas := make([dynamic]u8)
    defer {
        delete(vertices)
        delete(indices)
        delete(areas)
    }
    // Generate 3x3 grid with gaps to test complex topology
    grid_size := 3
    cell_size := f32(2.0)
    vert_idx: i32 = 0
    for y in 0..<grid_size {
        for x in 0..<grid_size {
            // Skip some cells to create gaps
            if (x + y) % 4 == 0 do continue
            x0, z0 := f32(x) * cell_size, f32(y) * cell_size
            x1, z1 := x0 + cell_size, z0 + cell_size
            // Add quad vertices and triangles
            append(&vertices, [3]f32{x0, 0, z0})
            append(&vertices, [3]f32{x1, 0, z0})
            append(&vertices, [3]f32{x1, 0, z1})
            append(&vertices, [3]f32{x0, 0, z1})
            append(&indices, vert_idx+0, vert_idx+1, vert_idx+2)
            append(&indices, vert_idx+0, vert_idx+2, vert_idx+3)
            append(&areas, recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA)
            vert_idx += 4
        }
    }
    testing.expect(t, len(vertices) > 0, "Should generate vertices")
    testing.expect(t, len(indices) > 0, "Should generate indices")
    testing.expect(t, len(indices) % 3 == 0, "Should have complete triangles")
    config := recast.Config{
        cs = 0.5,
        ch = 0.5,
        walkable_slope_angle = 45,
        walkable_height = 2,
        walkable_climb = 1,
        walkable_radius = 1,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 6,
        detail_sample_max_error = 1,
    }
    pmesh, dmesh, ok := recast.build_navmesh(vertices[:], indices[:], areas[:], config)
    testing.expect(t, ok, "Complex geometry build should succeed")
    defer recast.free_poly_mesh(pmesh)
    defer recast.free_poly_mesh_detail(dmesh)
    // Validate comprehensive results
    testing.expect(t, pmesh != nil, "Should generate polygon mesh")
    testing.expect(t, dmesh != nil, "Should generate detail mesh")
    testing.expect(t, pmesh.npolys > 0, "Should generate polygons")
    testing.expect(t, len(pmesh.verts) > 0, "Should generate vertices")
    testing.expect(t, len(dmesh.verts) > 0, "Should generate detail vertices")
    // Validate mesh connectivity for complex topology
    connected_polys := 0
    for i in 0..<pmesh.npolys {
        poly_base := int(i) * int(pmesh.nvp) * 2
        has_neighbors := false
        for j in 0..<pmesh.nvp {
            if pmesh.polys[poly_base + int(pmesh.nvp) + int(j)] != recast.RC_MESH_NULL_IDX {
                has_neighbors = true
                break
            }
        }
        if has_neighbors do connected_polys += 1
    }
    // Most polygons should be connected for walkable areas
    if pmesh.npolys > 1 {
        connection_ratio := f32(connected_polys) / f32(pmesh.npolys)
        testing.expect(t, connection_ratio >= 0.5, "Most polygons should be connected")
    }
}
