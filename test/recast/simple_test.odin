package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_basic_heightfield :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    
    // Create simple test geometry - a 10x10 flat square
    verts := []f32{
        0, 0, 0,    // vertex 0
        10, 0, 0,   // vertex 1  
        10, 0, 10,  // vertex 2
        0, 0, 10,   // vertex 3
    }
    
    tris := []i32{
        0, 1, 2,    // triangle 0
        0, 2, 3,    // triangle 1
    }
    
    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_WALKABLE_AREA,
    }
    
    // Create config
    cfg := nav_recast.Config{}
    cfg.cs = 0.5  // Cell size
    cfg.ch = 0.2  // Cell height
    cfg.walkable_slope_angle = 45.0
    cfg.walkable_height = 2
    cfg.walkable_climb = 1
    cfg.walkable_radius = 1
    
    // Calculate bounds manually to debug
    cfg.bmin = {0, 0, 0}
    cfg.bmax = {10, 0, 10}
    
    log.infof("Manual bounds: min=%v, max=%v", cfg.bmin, cfg.bmax)
    
    // Calculate grid size
    cfg.width = i32((cfg.bmax.x - cfg.bmin.x) / cfg.cs)
    cfg.height = i32((cfg.bmax.z - cfg.bmin.z) / cfg.cs)
    
    log.infof("Grid size: %dx%d", cfg.width, cfg.height)
    
    // Create heightfield
    hf := nav_recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation failed")
    defer nav_recast.free_heightfield(hf)
    
    ok := nav_recast.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Heightfield creation failed")
    
    // Verify heightfield properties
    testing.expect_value(t, hf.width, cfg.width)
    testing.expect_value(t, hf.height, cfg.height)
    testing.expect_value(t, hf.cs, cfg.cs)
    testing.expect_value(t, hf.ch, cfg.ch)
    
    // Rasterize triangles
    ok = nav_recast.rasterize_triangles(verts, 4, tris, areas, 2, hf, cfg.walkable_climb)
    testing.expect(t, ok, "Triangle rasterization failed")
    
    // Count non-empty cells
    non_empty_cells := 0
    for i in 0..<len(hf.spans) {
        if hf.spans[i] != nil {
            non_empty_cells += 1
        }
    }
    
    log.infof("Non-empty cells: %d/%d", non_empty_cells, len(hf.spans))
    testing.expect(t, non_empty_cells > 0, "No cells were rasterized")
    
    log.info("✓ Basic heightfield test passed")
}

@(test) 
test_simple_api :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    
    // Create simple test geometry
    verts := []f32{
        0, 0, 0,
        10, 0, 0,
        10, 0, 10,
        0, 0, 10,
    }
    
    tris := []i32{
        0, 1, 2,
        0, 2, 3,
    }
    
    // Use the quick build function
    // Create areas array
    areas := make([]u8, len(tris)/3)
    defer delete(areas)
    for i in 0..<len(areas) {
        areas[i] = nav_recast.RC_WALKABLE_AREA
    }
    
    // Create config
    cfg := nav_recast.Config{
        cs = 0.3,
        ch = 0.3,
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
    
    pmesh, dmesh, ok := nav_recast.build_navmesh(verts, tris, areas, cfg)
    testing.expect(t, ok, "Quick build should succeed")
    if !ok {
        log.error("Build failed")
        return
    }
    
    defer nav_recast.free_poly_mesh(pmesh)
    defer nav_recast.free_poly_mesh_detail(dmesh)
    
    testing.expect(t, pmesh != nil, "Should have polygon mesh")
    testing.expect(t, pmesh.npolys > 0, "Should have polygons")
    
    log.infof("Quick build: %d polygons", pmesh.npolys)
    log.info("✓ Simple API test passed")
}