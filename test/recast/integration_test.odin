package test_recast

import nav_recast "../../mjolnir/navigation/recast"  
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"

// Helper to create test configuration
create_test_config :: proc(cs, ch: f32) -> nav_recast.Config {
    cfg := nav_recast.Config{}
    cfg.cs = cs
    cfg.ch = ch
    cfg.walkable_slope_angle = 45.0
    cfg.walkable_height = 2
    cfg.walkable_climb = 1
    cfg.walkable_radius = 1
    cfg.max_edge_len = 12
    cfg.max_simplification_error = 1.3
    cfg.min_region_area = 8
    cfg.merge_region_area = 20
    cfg.max_verts_per_poly = 6
    cfg.detail_sample_dist = 6
    cfg.detail_sample_max_error = 1
    return cfg
}

@(test)
test_complete_navmesh_generation_simple :: proc(t: ^testing.T) {
    // Test complete navigation mesh generation with a simple flat floor

    // Define a simple square floor
    verts := []f32{
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20,
    }

    tris := []i32{
        0, 1, 2,
        0, 2, 3,
    }

    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_WALKABLE_AREA,
    }

    // Create config
    cfg := create_test_config(0.3, 0.2)

    // Calculate bounds
    cfg.bmin, cfg.bmax = recast.calc_bounds(verts, 4)

    // Calculate grid size
    cfg.width, cfg.height = recast.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)

    // Create heightfield
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Failed to create heightfield")

    // Rasterize triangles
    ok = recast.rasterize_triangles(verts, 4, tris, areas, 2, hf, cfg.walkable_climb)
    testing.expect(t, ok, "Failed to rasterize triangles")

    // Apply filters
    recast.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    recast.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    recast.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)

    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    testing.expect(t, chf.span_count > 0, "No spans in compact heightfield")

    // Erode walkable area
    ok = recast.erode_walkable_area(cfg.walkable_radius, chf)
    testing.expect(t, ok, "Failed to erode walkable area")

    // Build distance field
    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")
    testing.expect(t, chf.max_distance > 0, "Invalid max distance")

    // Build regions
    ok = recast.build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
    testing.expect(t, ok, "Failed to build regions")
    testing.expect(t, chf.max_regions > 0, "No regions created")

    // Build contours
    cset := recast.alloc_contour_set()
    testing.expect(t, cset != nil, "Failed to allocate contour set")
    defer recast.free_contour_set(cset)

    ok = recast.build_contours(chf, cfg.max_simplification_error, cfg.max_edge_len, cset)
    testing.expect(t, ok, "Failed to build contours")

    // THOROUGH VALIDATION: Verify algorithmic correctness of complete pipeline
    // 1. Validate heightfield rasterization created correct spans
    total_rasterized_cells := 0
    for y in 0..<hf.height {
        for x in 0..<hf.width {
            col_idx := x + y * hf.width
            if hf.spans[col_idx] != nil {
                total_rasterized_cells += 1
            }
        }
    }
    testing.expect(t, total_rasterized_cells > 0, 
                  "Heightfield should contain rasterized geometry")
    
    // 2. Validate compact heightfield preserved walkable spans
    walkable_spans := 0
    for i in 0..<chf.span_count {
        if chf.areas[i] == nav_recast.RC_WALKABLE_AREA {
            walkable_spans += 1
        }
    }
    testing.expect(t, walkable_spans > 0, 
                  "Compact heightfield should preserve walkable spans")
    
    // 3. Validate region building created proper connectivity
    // Each region should have reasonable size for the input geometry
    region_sizes := map[u16]int{}
    defer delete(region_sizes)
    for i in 0..<chf.span_count {
        if chf.areas[i] != nav_recast.RC_NULL_AREA {
            reg := chf.spans[i].reg
            if reg != 0 {
                region_sizes[reg] = region_sizes[reg] + 1
            }
        }
    }
    
    // For a simple 20x20 floor, expect reasonable region sizes
    testing.expect(t, len(region_sizes) > 0, 
                  "Should create at least one region")
    
    // Validate largest region represents most of the walkable area
    largest_region_size := 0
    for _, size in region_sizes {
        if size > largest_region_size {
            largest_region_size = size
        }
    }
    testing.expect(t, largest_region_size >= walkable_spans / 2, 
                  "Largest region should represent significant portion of walkable area")
    
    // 4. Validate contour generation produced reasonable boundary representation
    total_contour_verts := 0
    for i in 0..<len(cset.conts) {
        if i32(i) < i32(len(cset.conts)) {
            total_contour_verts += len(cset.conts[i].verts)
        }
    }
    testing.expect(t, total_contour_verts >= 4, 
                  "Should generate contours with at least 4 vertices for rectangular geometry")

    log.infof("Navigation mesh validation: %d regions, %d walkable spans, %d contour vertices, grid %dx%d",
              len(region_sizes), walkable_spans, total_contour_verts, cfg.width, cfg.height)
}

@(test)
test_navmesh_with_obstacles :: proc(t: ^testing.T) {
    // Test navigation mesh generation with obstacles

    // Define a floor with a box obstacle in the middle
    verts := []f32{
        // Floor
        0, 0, 0,
        30, 0, 0,
        30, 0, 30,
        0, 0, 30,
        // Obstacle box (raised platform)
        10, 0, 10,
        20, 0, 10,
        20, 0, 20,
        10, 0, 20,
        10, 5, 10,
        20, 5, 10,
        20, 5, 20,
        10, 5, 20,
    }

    tris := []i32{
        // Floor
        0, 1, 2,
        0, 2, 3,
        // Obstacle sides
        4, 8, 9,
        4, 9, 5,
        5, 9, 10,
        5, 10, 6,
        6, 10, 11,
        6, 11, 7,
        7, 11, 8,
        7, 8, 4,
        // Obstacle top
        8, 9, 10,
        8, 10, 11,
    }

    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_NULL_AREA,  // Side walls are not walkable
        nav_recast.RC_NULL_AREA,
        nav_recast.RC_NULL_AREA,
        nav_recast.RC_NULL_AREA,
        nav_recast.RC_NULL_AREA,
        nav_recast.RC_NULL_AREA,
        nav_recast.RC_NULL_AREA,
        nav_recast.RC_NULL_AREA,
        nav_recast.RC_WALKABLE_AREA,  // Top is walkable
        nav_recast.RC_WALKABLE_AREA,
    }

    // Create config
    cfg := create_test_config(0.3, 0.2)

    // Calculate bounds
    cfg.bmin, cfg.bmax = recast.calc_bounds(verts, 12)

    // Calculate grid size
    cfg.width, cfg.height = recast.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)

    // Create heightfield
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Failed to create heightfield")

    // Rasterize triangles
    ok = recast.rasterize_triangles(verts, 12, tris, areas, 12, hf, cfg.walkable_climb)
    testing.expect(t, ok, "Failed to rasterize triangles")

    // Apply filters
    recast.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    recast.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    recast.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)

    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Erode walkable area
    ok = recast.erode_walkable_area(cfg.walkable_radius, chf)
    testing.expect(t, ok, "Failed to erode walkable area")

    // Apply median filter
    ok = recast.median_filter_walkable_area(chf)
    testing.expect(t, ok, "Failed to apply median filter")

    // Build distance field
    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    // Build regions
    ok = recast.build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
    testing.expect(t, ok, "Failed to build regions")

    // THOROUGH VALIDATION: Verify obstacle handling correctness
    // 1. Count regions by height level to validate separation
    ground_level_spans := 0
    elevated_level_spans := 0
    
    for i in 0..<chf.span_count {
        if chf.areas[i] != nav_recast.RC_NULL_AREA {
            span := &chf.spans[i]
            span_height := span.y
            
            // Ground level spans should be at low height
            if span_height <= 5 {
                ground_level_spans += 1
            } else {
                elevated_level_spans += 1
            }
        }
    }
    
    // Should have both ground and elevated areas
    testing.expect(t, ground_level_spans > 0, 
                  "Should have ground level walkable areas")
    testing.expect(t, elevated_level_spans > 0, 
                  "Should have elevated walkable areas on obstacle")
    
    // 2. Validate region separation - floor and obstacle should be different regions
    region_heights := map[u16][dynamic]int{}
    defer {
        for reg, heights in region_heights {
            delete(heights)
        }
        delete(region_heights)
    }
    
    for i in 0..<chf.span_count {
        if chf.areas[i] != nav_recast.RC_NULL_AREA {
            reg := chf.spans[i].reg
            if reg != 0 {
                span := &chf.spans[i]
                if reg not_in region_heights {
                    region_heights[reg] = make([dynamic]int)
                }
                append(&region_heights[reg], int(span.y))
            }
        }
    }
    
    // Should have separate regions for different height levels
    testing.expect(t, len(region_heights) >= 2, 
                  "Should have at least 2 regions (ground + obstacle)")
    
    // Validate height separation between regions
    found_ground_region := false
    found_elevated_region := false
    
    for reg, heights in region_heights {
        avg_height := 0
        for h in heights {
            avg_height += h
        }
        avg_height /= len(heights)
        
        if avg_height <= 3 {
            found_ground_region = true
        } else if avg_height >= 15 {
            found_elevated_region = true
        }
    }
    
    testing.expect(t, found_ground_region, 
                  "Should have a region representing ground level")
    testing.expect(t, found_elevated_region, 
                  "Should have a region representing elevated obstacle")
    
    // 3. Validate obstacle area isolation
    // Count walkable cells in obstacle area (x[10-20], z[10-20])
    obstacle_area_spans := 0
    for y in 0..<chf.height {
        for x in 0..<chf.width {
            // Convert grid coordinates back to world coordinates
            world_x := f32(x) * cfg.cs + cfg.bmin.x
            world_z := f32(y) * cfg.cs + cfg.bmin.z
            
            if world_x >= 10 && world_x <= 20 && world_z >= 10 && world_z <= 20 {
                c := &chf.cells[x + y * chf.width]
                if c.count > 0 && c.index < u32(len(chf.spans)) {
                    end_idx := min(c.index + u32(c.count), u32(len(chf.spans)))
                    for i in c.index..<end_idx {
                        if i < u32(len(chf.areas)) && chf.areas[i] != nav_recast.RC_NULL_AREA {
                            obstacle_area_spans += 1
                        }
                    }
                }
            }
        }
    }
    
    testing.expect(t, obstacle_area_spans > 0, 
                  "Obstacle area should contain walkable spans on top surface")

    log.infof("Obstacle validation: %d regions, %d ground spans, %d elevated spans",
              len(region_heights), ground_level_spans, elevated_level_spans)
}

@(test)
test_navmesh_with_slopes :: proc(t: ^testing.T) {
    // Test navigation mesh generation with slopes

    // Define a sloped surface
    verts := []f32{
        0, 0, 0,
        20, 0, 0,
        20, 5, 20,  // Raised end
        0, 5, 20,   // Raised end
    }

    tris := []i32{
        0, 1, 2,
        0, 2, 3,
    }

    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_WALKABLE_AREA,
    }

    // Create config with specific slope angle
    cfg := create_test_config(0.3, 0.2)
    cfg.walkable_slope_angle = 30.0  // Allow 30 degree slopes

    // Calculate bounds
    cfg.bmin, cfg.bmax = recast.calc_bounds(verts, 4)

    // Calculate grid size
    cfg.width, cfg.height = recast.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)

    // Create heightfield
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Failed to create heightfield")

    // Rasterize triangles
    ok = recast.rasterize_triangles(verts, 4, tris, areas, 2, hf, cfg.walkable_climb)
    testing.expect(t, ok, "Failed to rasterize triangles")

    // Apply filters
    recast.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    recast.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    recast.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)

    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Build distance field
    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    // Build regions
    ok = recast.build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
    testing.expect(t, ok, "Failed to build regions")

    // Should have created walkable regions on the slope
    testing.expect(t, chf.max_regions > 0, "Slope should have walkable regions")

    log.infof("Navigation mesh with slopes: %d regions created", chf.max_regions)
}

@(test)
test_navmesh_area_marking :: proc(t: ^testing.T) {

    // Create a simple floor
    verts := []f32{
        0, 0, 0,
        40, 0, 0,
        40, 0, 40,
        0, 0, 40,
    }

    tris := []i32{
        0, 1, 2,
        0, 2, 3,
    }

    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_WALKABLE_AREA,
    }

    // Create config
    cfg := create_test_config(0.5, 0.2)

    // Calculate bounds and grid
    cfg.bmin, cfg.bmax = recast.calc_bounds(verts, 4)
    cfg.width, cfg.height = recast.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)

    // Create and build heightfield
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Failed to create heightfield")

    ok = recast.rasterize_triangles(verts, 4, tris, areas, 2, hf, cfg.walkable_climb)
    testing.expect(t, ok, "Failed to rasterize triangles")

    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Mark different areas

    // Mark a box area
    box_min := [3]f32{5, -1, 5}
    box_max := [3]f32{15, 10, 15}
    recast.mark_box_area(box_min, box_max, 10, chf)

    // Mark a cylinder area
    cylinder_pos := [3]f32{30, 0, 30}
    recast.mark_cylinder_area(cylinder_pos, 5.0, 10.0, 20, chf)

    // Mark a convex polygon area
    poly_verts := []f32{
        20, -1, 5,
        25, -1, 5,
        25, -1, 10,
        20, -1, 10,
    }
    recast.mark_convex_poly_area(poly_verts, 4, -1, 10, 30, chf)

    // Verify areas were marked
    marked_areas := map[u8]int{}
    defer delete(marked_areas)
    for i in 0..<chf.span_count {
        area := chf.areas[i]
        if area != nav_recast.RC_NULL_AREA {
            marked_areas[area] = marked_areas[area] + 1
        }
    }

    // Should have at least 3 different area types (walkable, box area, cylinder area)
    testing.expect(t, len(marked_areas) >= 3, "Should have multiple area types marked")
    testing.expect(t, 10 in marked_areas, "Box area should be marked")
    testing.expect(t, 20 in marked_areas, "Cylinder area should be marked")
    testing.expect(t, 30 in marked_areas, "Polygon area should be marked")

    log.infof("Area marking test: %d different area types", len(marked_areas))
}

@(test)
test_navmesh_performance :: proc(t: ^testing.T) {
    // Test performance with a larger mesh

    // Create a 10x10 grid of triangles
    grid_size := 10
    cell_size := f32(5.0)

    vert_count := (grid_size + 1) * (grid_size + 1)
    verts := make([]f32, vert_count * 3)
    defer delete(verts)

    // Generate vertices
    idx := 0
    for y in 0..=grid_size {
        for x in 0..=grid_size {
            verts[idx + 0] = f32(x) * cell_size
            verts[idx + 1] = 0
            verts[idx + 2] = f32(y) * cell_size
            idx += 3
        }
    }

    // Generate triangles
    tri_count := grid_size * grid_size * 2
    tris := make([]i32, tri_count * 3)
    areas := make([]u8, tri_count)
    defer delete(tris)
    defer delete(areas)

    idx = 0
    for y in 0..<grid_size {
        for x in 0..<grid_size {
            // First triangle
            tris[idx + 0] = i32(y * (grid_size + 1) + x)
            tris[idx + 1] = i32((y + 1) * (grid_size + 1) + x)
            tris[idx + 2] = i32((y + 1) * (grid_size + 1) + x + 1)

            // Second triangle
            tris[idx + 3] = i32(y * (grid_size + 1) + x)
            tris[idx + 4] = i32((y + 1) * (grid_size + 1) + x + 1)
            tris[idx + 5] = i32(y * (grid_size + 1) + x + 1)

            areas[idx/3] = nav_recast.RC_WALKABLE_AREA
            areas[idx/3 + 1] = nav_recast.RC_WALKABLE_AREA

            idx += 6
        }
    }

    // Create config
    cfg := create_test_config(0.3, 0.2)

    // Calculate bounds
    cfg.bmin, cfg.bmax = recast.calc_bounds(verts, i32(vert_count))

    // Calculate grid size
    cfg.width, cfg.height = recast.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)

    log.infof("Performance test: %d vertices, %d triangles, grid %dx%d",
              vert_count, tri_count, cfg.width, cfg.height)

    // Create heightfield
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Failed to create heightfield")

    // Rasterize triangles
    ok = recast.rasterize_triangles(verts, i32(vert_count), tris, areas, i32(tri_count), hf, cfg.walkable_climb)
    testing.expect(t, ok, "Failed to rasterize triangles")

    // Apply filters
    recast.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    recast.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    recast.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)

    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Build distance field
    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    // Build regions
    ok = recast.build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
    testing.expect(t, ok, "Failed to build regions")

    log.infof("Performance test complete: %d spans, %d regions", chf.span_count, chf.max_regions)
}

