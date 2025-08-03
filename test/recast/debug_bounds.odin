package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_debug_bounds :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create simple test geometry
    verts := []f32{
        0, 0, 0,    // vertex 0
        10, 0, 0,   // vertex 1
        10, 0, 10,  // vertex 2
        0, 0, 10,   // vertex 3
    }
    
    log.info("Input vertices:")
    for i in 0..<4 {
        log.infof("  v[%d] = (%.2f, %.2f, %.2f)", i, verts[i*3], verts[i*3+1], verts[i*3+2])
    }
    
    // Test bounds calculation
    bmin: [3]f32
    bmax: [3]f32
    
    log.info("Before rc_calc_bounds:")
    log.infof("  bmin = %v", bmin)
    log.infof("  bmax = %v", bmax)
    
    nav_recast.rc_calc_bounds(verts, 4, &bmin, &bmax)
    
    log.info("After rc_calc_bounds:")
    log.infof("  bmin = %v", bmin)
    log.infof("  bmax = %v", bmax)
    
    // Verify bounds
    testing.expect_value(t, bmin.x, f32(0))
    testing.expect_value(t, bmin.y, f32(0))
    testing.expect_value(t, bmin.z, f32(0))
    testing.expect_value(t, bmax.x, f32(10))
    testing.expect_value(t, bmax.y, f32(0))
    testing.expect_value(t, bmax.z, f32(10))
    
    // Test grid size calculation
    width, height: i32
    cs := f32(0.5)
    
    nav_recast.rc_calc_grid_size(&bmin, &bmax, cs, &width, &height)
    log.infof("Grid size with cs=%.2f: %dx%d", cs, width, height)
    
    testing.expect_value(t, width, i32(20))
    testing.expect_value(t, height, i32(20))
}