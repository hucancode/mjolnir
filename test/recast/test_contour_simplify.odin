package test_recast

import "core:testing"
import "core:log"
import "core:math"
import "core:math/linalg"
import nav "../../mjolnir/navigation/recast"

@(test)
test_simplify_contour_distance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Contour Simplification Distance Calculation ===")

    // Test distance calculation algorithm
    test_cases := []struct {
        px, pz: i32,  // Point
        ax, az: i32,  // Segment start
        bx, bz: i32,  // Segment end
        description: string,
    }{
        {5, 5, 0, 0, 10, 0, "Point (5,5) to horizontal segment (0,0)-(10,0)"},
        {5, 5, 0, 0, 0, 10, "Point (5,5) to vertical segment (0,0)-(0,10)"},
        {5, 0, 0, 0, 10, 0, "Point (5,0) on horizontal segment (0,0)-(10,0)"},
        {15, 5, 0, 0, 10, 0, "Point (15,5) outside horizontal segment (0,0)-(10,0)"},
    }

    for test_case in test_cases {
        // Calculate distance using Odin logic (from distance_pt_seg)
        dx := f32(test_case.bx - test_case.ax)
        dz := f32(test_case.bz - test_case.az)

        t_val: f32
        if abs(dx) < 0.0001 && abs(dz) < 0.0001 {
            // Degenerate segment
            dist_sq := (f32(test_case.px - test_case.ax) * f32(test_case.px - test_case.ax)) +
                      (f32(test_case.pz - test_case.az) * f32(test_case.pz - test_case.az))
            log.infof("%s", test_case.description)
            log.infof("  Degenerate segment, distance^2 = %f, distance = %f", dist_sq, math.sqrt(dist_sq))
        } else {
            t_val = ((f32(test_case.px - test_case.ax) * dx) + (f32(test_case.pz - test_case.az) * dz)) / (dx*dx + dz*dz)
            t_val = linalg.saturate(t_val)
            nearx := f32(test_case.ax) + t_val * dx
            nearz := f32(test_case.az) + t_val * dz

            dx_near := f32(test_case.px) - nearx
            dz_near := f32(test_case.pz) - nearz

            dist_sq := dx_near*dx_near + dz_near*dz_near

            log.infof("%s", test_case.description)
            log.infof("  t = %f, distance^2 = %f, distance = %f", t_val, dist_sq, math.sqrt(dist_sq))
        }
    }

    // Test hasConnections logic
    log.info("\n=== Testing hasConnections logic ===")

    // Test case 1: No connections (all flags are 0)
    {
        test_verts := [][4]i32{
            {0, 0, 0, 0},
            {10, 0, 0, 0},
            {20, 0, 0, 0},
            {30, 0, 0, 0},
        }

        has_connections := false
        for v in test_verts {
            if (v[3] & nav.RC_CONTOUR_REG_MASK) != 0 {
                has_connections = true
                break
            }
        }
        log.infof("Test 1 - No connections: has_connections = %v", has_connections)
        testing.expect_value(t, has_connections, false)
    }

    // Test case 2: With region connections
    {
        test_verts := [][4]i32{
            {0, 0, 0, 0},
            {10, 0, 0, 0},
            {20, 0, 0, 0x1234},  // Has region
            {30, 0, 0, 0},
        }

        has_connections := false
        for v in test_verts {
            if (v[3] & nav.RC_CONTOUR_REG_MASK) != 0 {
                has_connections = true
                break
            }
        }
        log.infof("Test 2 - With region at index 2: has_connections = %v", has_connections)
        log.infof("  RC_CONTOUR_REG_MASK = 0x%x", nav.RC_CONTOUR_REG_MASK)
        testing.expect_value(t, has_connections, true)
    }
}

@(test)
test_simplify_contour_algorithm :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Contour Simplification Algorithm ===")

    // Create test raw contour points (a simple square with extra points)
    raw_verts := [][4]i32{
        // Bottom edge (with extra points)
        {0, 0, 0, 0},
        {5, 0, 0, 0},
        {10, 0, 0, 0},
        // Right edge (with extra points)
        {10, 0, 5, 0},
        {10, 0, 10, 0},
        // Top edge (with extra points)
        {5, 0, 10, 0},
        {0, 0, 10, 0},
        // Left edge (with extra points)
        {0, 0, 5, 0},
    }

    log.info("Raw contour points (x, y, z, flags):")
    for v, i in raw_verts {
        log.infof("  [%d]: (%d, %d, %d, 0x%x)", i, v[0], v[1], v[2], v[3])
    }

    // Test different error tolerances
    max_errors := []f32{0.01, 0.5, 1.0, 2.0}
    max_edge_len: i32 = 12

    for max_error in max_errors {
        log.infof("\n=== Simplification with maxError=%f ===", max_error)

        simplified := make([dynamic][4]i32, 0)
        defer delete(simplified)

        nav.simplify_contour(raw_verts, &simplified, max_error, 1.0, max_edge_len)

        log.infof("Simplified points: %d vertices", len(simplified))
        for v, i in simplified {
            log.infof("  [%d]: (%d, %d, %d, 0x%x)", i, v[0], v[1], v[2], v[3])
        }
    }

    // Test with region connections
    log.info("\n=== Testing with Region Connections ===")
    {
        raw_verts_with_regions := [][4]i32{
            {0, 0, 0, 0},
            {10, 0, 0, 0x1000},  // Region change
            {20, 0, 0, 0x1000},
            {20, 0, 10, 0x2000}, // Another region change
            {10, 0, 10, 0x2000},
            {0, 0, 10, 0},
        }

        simplified := make([dynamic][4]i32, 0)
        defer delete(simplified)

        nav.simplify_contour(raw_verts_with_regions, &simplified, 1.0, 1.0, 12)

        log.infof("Simplified with regions: %d vertices", len(simplified))
        for v, i in simplified {
            log.infof("  [%d]: (%d, %d, %d, 0x%x)", i, v[0], v[1], v[2], v[3])
        }
    }
}

import "core:time"
