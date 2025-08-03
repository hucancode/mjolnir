package navigation_recast

import "core:mem"
import "core:log"

// Build navigation mesh from triangle mesh
// This is the main entry point - follows C++ API closely
rc_build_navmesh :: proc(vertices: []f32, indices: []i32, areas: []u8, cfg: Config) -> (pmesh: ^Rc_Poly_Mesh, dmesh: ^Rc_Poly_Mesh_Detail, ok: bool) {
    // Validate inputs
    if len(vertices) == 0 || len(indices) == 0 || cfg.cs <= 0 || cfg.ch <= 0 {
        return nil, nil, false
    }
    
    // Calculate bounds if needed
    config := cfg
    if config.bmin == {} && config.bmax == {} {
        rc_calc_bounds(vertices, i32(len(vertices)/3), &config.bmin, &config.bmax)
    }
    
    // Debug log bounds
    log.infof("Navigation mesh bounds: min=(%.2f, %.2f, %.2f), max=(%.2f, %.2f, %.2f)",
              config.bmin.x, config.bmin.y, config.bmin.z,
              config.bmax.x, config.bmax.y, config.bmax.z)
    
    // Calculate grid size
    rc_calc_grid_size(&config.bmin, &config.bmax, config.cs, &config.width, &config.height)
    
    log.infof("Grid size: %d x %d (cell size=%.2f)", config.width, config.height, config.cs)
    
    // Validate grid size
    if config.width <= 0 || config.height <= 0 {
        return nil, nil, false
    }
    
    // Build heightfield
    hf := rc_alloc_heightfield()
    defer rc_free_heightfield(hf)
    
    if !rc_create_heightfield(hf, config.width, config.height, config.bmin, config.bmax, config.cs, config.ch) {
        return nil, nil, false
    }
    
    // Debug: Check areas before rasterization
    when ODIN_DEBUG {
        log.infof("Rasterizing %d triangles with areas:", len(indices)/3)
        for i in 0..<min(10, len(areas)) {
            log.infof("  Triangle %d: area=%d", i, areas[i])
        }
    }
    
    if !rc_rasterize_triangles(vertices, i32(len(vertices)/3), indices, areas, i32(len(indices)/3), hf, config.walkable_climb) {
        return nil, nil, false
    }
    
    // Debug: Count spans in heightfield
    when ODIN_DEBUG {
        span_count := 0
        for y in 0..<hf.height {
            for x in 0..<hf.width {
                s := hf.spans[x + y * hf.width]
                for s != nil {
                    if s.area != RC_NULL_AREA {
                        span_count += 1
                    }
                    s = s.next
                }
            }
        }
        log.infof("Heightfield after rasterization: %d walkable spans", span_count)
        
        // Check span distribution
        quadrants := [4]int{0, 0, 0, 0}  // NE, NW, SW, SE
        mid_x := hf.width / 2
        mid_z := hf.height / 2
        for y in 0..<hf.height {
            for x in 0..<hf.width {
                s := hf.spans[x + y * hf.width]
                if s != nil && s.area != RC_NULL_AREA {
                    quad := 0
                    if x < mid_x && y < mid_z do quad = 2  // SW
                    else if x >= mid_x && y < mid_z do quad = 3  // SE
                    else if x < mid_x && y >= mid_z do quad = 1  // NW
                    else do quad = 0  // NE
                    quadrants[quad] += 1
                }
            }
        }
        log.infof("Span distribution by quadrant: NE=%d, NW=%d, SW=%d, SE=%d", 
                  quadrants[0], quadrants[1], quadrants[2], quadrants[3])
    }
    
    // Filter walkable surfaces
    rc_filter_low_hanging_walkable_obstacles(int(config.walkable_climb), hf)
    rc_filter_ledge_spans(int(config.walkable_height), int(config.walkable_climb), hf)
    rc_filter_walkable_low_height_spans(int(config.walkable_height), hf)
    
    // Debug: Count spans after filtering
    when ODIN_DEBUG {
        span_count2 := 0
        quadrants2 := [4]int{0, 0, 0, 0}  // NE, NW, SW, SE
        mid_x2 := hf.width / 2
        mid_z2 := hf.height / 2
        for y in 0..<hf.height {
            for x in 0..<hf.width {
                s := hf.spans[x + y * hf.width]
                for s != nil {
                    if s.area != RC_NULL_AREA {
                        span_count2 += 1
                        quad := 0
                        if x < mid_x2 && y < mid_z2 do quad = 2  // SW
                        else if x >= mid_x2 && y < mid_z2 do quad = 3  // SE
                        else if x < mid_x2 && y >= mid_z2 do quad = 1  // NW
                        else do quad = 0  // NE
                        quadrants2[quad] += 1
                    }
                    s = s.next
                }
            }
        }
        log.infof("Heightfield after filtering: %d walkable spans", span_count2)
        log.infof("After filtering distribution: NE=%d, NW=%d, SW=%d, SE=%d", 
                  quadrants2[0], quadrants2[1], quadrants2[2], quadrants2[3])
    }
    
    // Build compact heightfield
    chf := rc_alloc_compact_heightfield()
    defer rc_free_compact_heightfield(chf)
    
    if !rc_build_compact_heightfield(config.walkable_height, config.walkable_climb, hf, chf) {
        return nil, nil, false
    }
    
    if !rc_erode_walkable_area(config.walkable_radius, chf) {
        return nil, nil, false
    }
    

    
    if !rc_build_distance_field(chf) {
        return nil, nil, false
    }
    
    if !rc_build_regions(chf, 0, config.min_region_area, config.merge_region_area) {
        return nil, nil, false
    }
    

    
    // Build contours
    cset := rc_alloc_contour_set()
    defer rc_free_contour_set(cset)
    
    if !rc_build_contours(chf, config.max_simplification_error, config.max_edge_len, cset) {
        return nil, nil, false
    }
    

    
    // Build polygon mesh
    pmesh = rc_alloc_poly_mesh()
    if !rc_build_poly_mesh(cset, config.max_verts_per_poly, pmesh) {
        rc_free_poly_mesh(pmesh)
        return nil, nil, false
    }
    
    // Build detail mesh
    dmesh = rc_alloc_poly_mesh_detail()
    if !rc_build_poly_mesh_detail(pmesh, chf, config.detail_sample_dist, config.detail_sample_max_error, dmesh) {
        rc_free_poly_mesh(pmesh)
        rc_free_poly_mesh_detail(dmesh)
        return nil, nil, false
    }
    
    return pmesh, dmesh, true
}