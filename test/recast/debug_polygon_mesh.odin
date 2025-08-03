package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import nav "../../mjolnir/navigation"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_debug_polygon_mesh :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Create simple test geometry
    verts := make([]f32, 12)
    verts[0] = 0; verts[1] = 0; verts[2] = 0     // vertex 0
    verts[3] = 10; verts[4] = 0; verts[5] = 0    // vertex 1
    verts[6] = 10; verts[7] = 0; verts[8] = 10   // vertex 2
    verts[9] = 0; verts[10] = 0; verts[11] = 10  // vertex 3
    defer delete(verts)
    
    tris := make([]i32, 6)
    tris[0] = 0; tris[1] = 1; tris[2] = 2    // triangle 0
    tris[3] = 0; tris[4] = 2; tris[5] = 3    // triangle 1
    defer delete(tris)
    
    areas := make([]u8, 2)
    areas[0] = nav_recast.RC_WALKABLE_AREA
    areas[1] = nav_recast.RC_WALKABLE_AREA
    defer delete(areas)
    
    // Create config
    cfg := nav_recast.Config{}
    cfg.cs = 0.5
    cfg.ch = 0.2
    cfg.walkable_height = 2
    cfg.walkable_climb = 1
    cfg.walkable_radius = 1
    cfg.min_region_area = 8
    cfg.merge_region_area = 20
    cfg.max_edge_len = 12
    cfg.max_simplification_error = 1.3
    cfg.max_verts_per_poly = 6
    
    // Calculate bounds
    nav_recast.rc_calc_bounds(verts, 4, &cfg.bmin, &cfg.bmax)
    nav_recast.rc_calc_grid_size(&cfg.bmin, &cfg.bmax, cfg.cs, &cfg.width, &cfg.height)
    
    log.infof("Config: bmin=%v, bmax=%v, grid=%dx%d", cfg.bmin, cfg.bmax, cfg.width, cfg.height)
    
    // Build through the pipeline
    hf := nav_recast.rc_alloc_heightfield()
    defer nav_recast.rc_free_heightfield(hf)
    
    nav_recast.rc_create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    nav_recast.rc_rasterize_triangles(verts, 4, tris, areas, 2, hf, cfg.walkable_climb)
    
    nav_recast.rc_filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    nav_recast.rc_filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    nav_recast.rc_filter_walkable_low_height_spans(int(cfg.walkable_height), hf)
    
    chf := nav_recast.rc_alloc_compact_heightfield()
    defer nav_recast.rc_free_compact_heightfield(chf)
    
    nav_recast.rc_build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf)
    nav_recast.rc_erode_walkable_area(cfg.walkable_radius, chf)
    nav_recast.rc_build_distance_field(chf)
    nav_recast.rc_build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
    
    cset := nav_recast.rc_alloc_contour_set()
    defer nav_recast.rc_free_contour_set(cset)
    
    nav_recast.rc_build_contours(chf, cfg.max_simplification_error, cfg.max_edge_len, cset)
    
    // Build polygon mesh
    pmesh := nav_recast.rc_alloc_poly_mesh()
    testing.expect(t, pmesh != nil, "Polygon mesh allocation failed")
    defer nav_recast.rc_free_poly_mesh(pmesh)
    
    ok := nav_recast.rc_build_poly_mesh(cset, cfg.max_verts_per_poly, pmesh)
    testing.expect(t, ok, "Polygon mesh building failed")
    
    log.infof("Polygon mesh: %d vertices, %d polygons", len(pmesh.verts), pmesh.npolys)
    log.infof("Mesh bounds: bmin=%v, bmax=%v", pmesh.bmin, pmesh.bmax)
    
    // Check first few vertices
    for i in 0..<min(10, len(pmesh.verts)) {
        v := pmesh.verts[i]
        x := f32(v[0]) * pmesh.cs + pmesh.bmin.x
        y := f32(v[1]) * pmesh.ch + pmesh.bmin.y
        z := f32(v[2]) * pmesh.cs + pmesh.bmin.z
        
        log.infof("Vertex %d: stored=(%d,%d,%d), world=(%.2f,%.2f,%.2f)", 
                  i, v[0], v[1], v[2],
                  x, y, z)
    }
}