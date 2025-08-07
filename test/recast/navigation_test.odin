package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"

@(test)
test_basic_navigation_mesh_generation :: proc(t: ^testing.T) {
    
    // Define some simple triangle data
    verts := [][3]f32{
        // Triangle 1
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        // Triangle 2
        {0, 0, 0},
        {10, 0, 10},
        {0, 0, 10},
    }
    
    tris := []i32{
        0, 1, 2,
        3, 4, 5,
    }
    
    // Mark triangles as walkable
    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_WALKABLE_AREA,
    }
    
    // Create navigation mesh config
    cfg := recast.config_create()
    cfg.cs = 0.3                // Cell size
    cfg.ch = 0.2                // Cell height
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
    
    // Calculate bounds
    cfg.bmin, cfg.bmax = recast.calc_bounds(verts)
    
    // Calculate grid size
    cfg.width, cfg.height = recast.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)
    
    testing.expect_value(t, cfg.width, 33)
    testing.expect_value(t, cfg.height, 33)
    
    // Create heightfield
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)
    
    ok := recast.create_heightfield(hf, cfg.width, cfg.height, 
                                      cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Rasterize triangles
    ok = recast.rasterize_triangles(verts, tris, areas, hf, 1)
    testing.expect(t, ok, "Failed to rasterize triangles")
    
    // Filter walkable surfaces
    recast.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    recast.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    recast.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)
    
    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
    defer recast.free_compact_heightfield(chf)
    
    ok = recast.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    testing.expect(t, chf.width == 33, "Unexpected compact heightfield width")
    testing.expect(t, chf.height == 33, "Unexpected compact heightfield height")
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
}

@(test)
test_basic_heightfield_creation :: proc(t: ^testing.T) {
    // Test heightfield allocation
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)
    
    // Test heightfield creation with various sizes
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{100, 10, 100}
    
    ok := recast.create_heightfield(hf, 100, 100, bmin, bmax, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create 100x100 heightfield")
    testing.expect_value(t, hf.width, 100)
    testing.expect_value(t, hf.height, 100)
    testing.expect_value(t, hf.cs, 1.0)
    testing.expect_value(t, hf.ch, 0.5)
}

@(test)
test_bounds_calculation :: proc(t: ^testing.T) {
    // Test with a simple cube
    verts := [][3]f32{
        {0, 0, 0},
        {1, 0, 0},
        {1, 1, 0},
        {0, 1, 0},
        {0, 0, 1},
        {1, 0, 1},
        {1, 1, 1},
        {0, 1, 1},
    }
    
    bmin, bmax: [3]f32
    bmin, bmax = recast.calc_bounds(verts)
    
    testing.expect_value(t, bmin.x, 0.0)
    testing.expect_value(t, bmin.y, 0.0)
    testing.expect_value(t, bmin.z, 0.0)
    testing.expect_value(t, bmax.x, 1.0)
    testing.expect_value(t, bmax.y, 1.0)
    testing.expect_value(t, bmax.z, 1.0)
}

@(test)
test_grid_size_calculation :: proc(t: ^testing.T) {
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{10, 5, 20}
    
    width, height: i32
    
    // Test with cell size 1.0
    width, height = recast.calc_grid_size(bmin, bmax, 1.0)
    testing.expect_value(t, width, 10)
    testing.expect_value(t, height, 20)
    
    // Test with cell size 0.5
    width, height = recast.calc_grid_size(bmin, bmax, 0.5)
    testing.expect_value(t, width, 20)
    testing.expect_value(t, height, 40)
}

@(test)
test_compact_heightfield_spans :: proc(t: ^testing.T) {
    // Create a simple heightfield with one span
    hf := recast.alloc_heightfield()
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{1, 1, 1}
    ok := recast.create_heightfield(hf, 1, 1, bmin, bmax, 1.0, 0.1)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Add a span manually
    ok = recast.add_span(hf, 0, 0, 0, 10, nav_recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span")
    
    // Build compact heightfield
    chf := recast.alloc_compact_heightfield()
    defer recast.free_compact_heightfield(chf)
    
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    testing.expect_value(t, chf.span_count, i32(1))
}