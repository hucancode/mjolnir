package navigation_recast

import "core:mem"
import "core:log"
import "core:math"
import "core:math/linalg"

// Build navigation mesh from triangle mesh
// This is the main entry point
build_navmesh :: proc(vertices: [][3]f32, indices: []i32, areas: []u8, cfg: Config) -> (pmesh: ^Poly_Mesh, dmesh: ^Poly_Mesh_Detail, ok: bool) {
    // Validate inputs
    if len(vertices) == 0 || len(indices) == 0 || cfg.cs <= 0 || cfg.ch <= 0 {
        return nil, nil, false
    }
    
    // Calculate bounds if needed
    config := cfg
    if config.bmin == {} && config.bmax == {} {
        config.bmin, config.bmax = calc_bounds(vertices)
    }
    
    // Debug log bounds
    log.infof("Navigation mesh bounds: min=(%.2f, %.2f, %.2f), max=(%.2f, %.2f, %.2f)",
              config.bmin.x, config.bmin.y, config.bmin.z,
              config.bmax.x, config.bmax.y, config.bmax.z)
    
    // Calculate grid size
    config.width, config.height = calc_grid_size(config.bmin, config.bmax, config.cs)
    
    log.infof("Grid size: %d x %d (cell size=%.2f)", config.width, config.height, config.cs)
    
    // Validate grid size
    if config.width <= 0 || config.height <= 0 {
        return nil, nil, false
    }
    
    // Build heightfield
    hf := alloc_heightfield()
    defer free_heightfield(hf)
    
    if !create_heightfield(hf, config.width, config.height, config.bmin, config.bmax, config.cs, config.ch) {
        return nil, nil, false
    }
    
    // Debug: Check areas before rasterization
    when ODIN_DEBUG {
        log.infof("Rasterizing %d triangles with areas:", len(indices)/3)
        for i in 0..<min(10, len(areas)) {
            log.infof("  Triangle %d: area=%d", i, areas[i])
        }
        
        // Also check if we're marking triangles as unwalkable due to slope
        walkable_thr := math.cos(config.walkable_slope_angle * math.PI / 180.0)
        log.infof("Walkable slope threshold: %.3f (angle=%.1f degrees)", walkable_thr, config.walkable_slope_angle)
        
        // Check first triangle normal
        if len(indices) >= 3 {
            v0 := vertices[indices[0]]
            v1 := vertices[indices[1]]
            v2 := vertices[indices[2]]
            
            e0 := v1 - v0
            e1 := v2 - v0
            norm := linalg.normalize(linalg.cross(e0, e1))
            
            log.infof("First triangle normal: (%.3f, %.3f, %.3f), Y=%.3f %s threshold %.3f", 
                      norm.x, norm.y, norm.z, norm.y, 
                      norm.y > walkable_thr ? ">" : "<=", walkable_thr)
        }
    }
    
    if !rasterize_triangles(vertices, indices, areas, hf, config.walkable_climb) {
        return nil, nil, false
    }
    
    // Debug: Count spans in heightfield
    when ODIN_DEBUG {
        span_count := 0
        null_area_count := 0
        total_spans := 0
        non_empty_cells := 0
        for y in 0..<hf.height {
            for x in 0..<hf.width {
                s := hf.spans[x + y * hf.width]
                if s != nil {
                    non_empty_cells += 1
                }
                for s != nil {
                    total_spans += 1
                    if s.area != RC_NULL_AREA {
                        span_count += 1
                    } else {
                        null_area_count += 1
                    }
                    s = s.next
                }
            }
        }
        log.infof("Heightfield after rasterization: %d total spans in %d non-empty cells", total_spans, non_empty_cells)
        log.infof("  %d walkable spans, %d null area spans", span_count, null_area_count)
        
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
    filter_low_hanging_walkable_obstacles(int(config.walkable_climb), hf)
    filter_ledge_spans(int(config.walkable_height), int(config.walkable_climb), hf)
    filter_walkable_low_height_spans(int(config.walkable_height), hf)
    
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
    chf := alloc_compact_heightfield()
    defer free_compact_heightfield(chf)
    
    if !build_compact_heightfield(config.walkable_height, config.walkable_climb, hf, chf) {
        return nil, nil, false
    }
    
    if !erode_walkable_area(config.walkable_radius, chf) {
        return nil, nil, false
    }
    

    
    if !build_distance_field(chf) {
        return nil, nil, false
    }
    
    if !build_regions(chf, 0, config.min_region_area, config.merge_region_area) {
        return nil, nil, false
    }
    

    
    // Build contours
    cset := alloc_contour_set()
    defer free_contour_set(cset)
    
    if !build_contours(chf, config.max_simplification_error, config.max_edge_len, cset) {
        return nil, nil, false
    }
    

    
    // Build polygon mesh
    pmesh = alloc_poly_mesh()
    if !build_poly_mesh(cset, config.max_verts_per_poly, pmesh) {
        free_poly_mesh(pmesh)
        return nil, nil, false
    }
    
    // Build detail mesh
    dmesh = alloc_poly_mesh_detail()
    if !build_poly_mesh_detail(pmesh, chf, config.detail_sample_dist, config.detail_sample_max_error, dmesh) {
        free_poly_mesh(pmesh)
        free_poly_mesh_detail(dmesh)
        return nil, nil, false
    }
    
    return pmesh, dmesh, true
}