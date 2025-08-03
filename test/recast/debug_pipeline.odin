package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import nav "../../mjolnir/navigation"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_debug_pipeline :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Create simple test geometry
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
    
    // Create config - initialize all fields explicitly
    cfg: nav_recast.Config
    cfg.cs = 0.5
    cfg.ch = 0.2
    cfg.walkable_slope_angle = 45.0
    cfg.walkable_height = 2
    cfg.walkable_climb = 1
    cfg.walkable_radius = 1
    cfg.max_edge_len = 12
    cfg.max_simplification_error = 1.3
    cfg.min_region_area = 8
    cfg.merge_region_area = 20
    cfg.max_verts_per_poly = 6
    cfg.detail_sample_dist = 6.0
    cfg.detail_sample_max_error = 1.0
    
    log.info("Config before bounds calculation:")
    log.infof("  bmin = %v", cfg.bmin)
    log.infof("  bmax = %v", cfg.bmax)
    log.infof("  width = %d, height = %d", cfg.width, cfg.height)
    
    // Calculate bounds
    nav_recast.rc_calc_bounds(verts, 4, &cfg.bmin, &cfg.bmax)
    
    log.info("Config after bounds calculation:")
    log.infof("  bmin = %v", cfg.bmin)
    log.infof("  bmax = %v", cfg.bmax)
    
    // Calculate grid size
    nav_recast.rc_calc_grid_size(&cfg.bmin, &cfg.bmax, cfg.cs, &cfg.width, &cfg.height)
    
    log.infof("Grid size: %dx%d", cfg.width, cfg.height)
    
    // Verify values
    testing.expect_value(t, cfg.bmin.x, f32(0))
    testing.expect_value(t, cfg.bmin.y, f32(0))
    testing.expect_value(t, cfg.bmin.z, f32(0))
    testing.expect_value(t, cfg.bmax.x, f32(10))
    testing.expect_value(t, cfg.bmax.y, f32(0))
    testing.expect_value(t, cfg.bmax.z, f32(10))
    testing.expect_value(t, cfg.width, i32(20))
    testing.expect_value(t, cfg.height, i32(20))
    
    // Create heightfield
    hf := nav_recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation failed")
    defer nav_recast.rc_free_heightfield(hf)
    
    log.infof("Creating heightfield with dimensions %dx%d", cfg.width, cfg.height)
    ok := nav_recast.rc_create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
    testing.expect(t, ok, "Heightfield creation failed")
    
    if ok {
        log.info("Heightfield created successfully!")
        log.infof("  hf.width = %d, hf.height = %d", hf.width, hf.height)
        log.infof("  hf.cs = %.2f, hf.ch = %.2f", hf.cs, hf.ch)
        log.infof("  spans array length = %d", len(hf.spans))
    }
}