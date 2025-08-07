package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"

@(test)
test_debug_helper :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create test geometry directly
    verts := [][3]f32{
        {0, 0, 0},    // vertex 0
        {10, 0, 0},   // vertex 1
        {10, 0, 10},  // vertex 2
        {0, 0, 10},   // vertex 3
    }
    
    tris := []i32{
        0, 1, 2,    // triangle 0
        0, 2, 3,    // triangle 1
    }
    
    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,
        nav_recast.RC_WALKABLE_AREA,
    }
    
    log.infof("verts length: %d", len(verts))
    log.infof("tris length: %d", len(tris))
    log.infof("areas length: %d", len(areas))
    
    // Print vertices
    for v, i in verts {
        log.infof("  v[%d] = (%.2f, %.2f, %.2f)", i, v.x, v.y, v.z)
    }
    
    // Test bounds calculation
    bmin: [3]f32
    bmax: [3]f32
    
    bmin, bmax = nav_recast.calc_bounds(verts)
    
    log.infof("Bounds: min=%v, max=%v", bmin, bmax)
    
    // Verify
    testing.expect_value(t, bmin.x, f32(0))
    testing.expect_value(t, bmin.y, f32(0))
    testing.expect_value(t, bmin.z, f32(0))
    testing.expect_value(t, bmax.x, f32(10))
    testing.expect_value(t, bmax.y, f32(0))
    testing.expect_value(t, bmax.z, f32(10))
}