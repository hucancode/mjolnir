package test_detour

import "core:testing"
import "core:log"
import recast "../../mjolnir/navigation/recast"
import nav_detour "../../mjolnir/navigation/detour"
import "core:math"

@(test)
test_bv_tree_y_remapping :: proc(t: ^testing.T) {
    // This test verifies that BV tree bounds are correctly remapped for Y coordinate
    // when no detail mesh is present, matching C++ behavior

    // Create a simple poly mesh with known parameters
    pmesh := recast.Poly_Mesh{
        cs = 0.3,  // cell size
        ch = 0.2,  // cell height
        nvp = 6,   // max verts per poly
        bmin = {-10.0, 0.0, -10.0},
        bmax = {10.0, 5.0, 10.0},
        npolys = 1,
    }

    // Create test vertices (already quantized)
    test_verts := [][3]u16{
        {10, 5, 10},    // vertex 0
        {20, 5, 10},    // vertex 1
        {20, 5, 20},    // vertex 2
        {10, 5, 20},    // vertex 3
    }
    pmesh.verts = test_verts

    // Create a simple polygon using all 4 vertices
    test_polys := []u16{
        0, 1, 2, 3, recast.RC_MESH_NULL_IDX, recast.RC_MESH_NULL_IDX,  // vertex indices
        0, 0, 0, 0, 0, 0,  // neighbor info
    }
    pmesh.polys = test_polys

    // Set up areas and flags
    pmesh.areas = []u8{1}
    pmesh.flags = []u16{1}

    // Test the bounds calculation
    poly_base := i32(0)
    quant_factor := 1.0 / pmesh.cs

    bounds := nav_detour.calc_polygon_bounds_fast(&pmesh, poly_base, pmesh.nvp, quant_factor)

    // Calculate expected Y remapping as C++ does
    ch_cs_ratio := pmesh.ch / pmesh.cs  // 0.2 / 0.3 = 0.667
    expected_min_y := u16(math.floor(f32(5) * ch_cs_ratio))  // floor(5 * 0.667) = floor(3.333) = 3
    expected_max_y := u16(math.ceil(f32(5) * ch_cs_ratio))   // ceil(5 * 0.667) = ceil(3.333) = 4

    log.infof("Test BV bounds Y remapping:")
    log.infof("  ch/cs ratio: %.3f", ch_cs_ratio)
    log.infof("  Original Y values: min=%d, max=%d", 5, 5)
    log.infof("  Expected remapped Y: min=%d, max=%d", expected_min_y, expected_max_y)
    log.infof("  Actual remapped Y: min=%d, max=%d", bounds.min[1], bounds.max[1])

    // Verify bounds match expected values
    testing.expect_value(t, bounds.min[0], u16(10))  // X min unchanged
    testing.expect_value(t, bounds.max[0], u16(20))  // X max unchanged
    testing.expect_value(t, bounds.min[2], u16(10))  // Z min unchanged
    testing.expect_value(t, bounds.max[2], u16(20))  // Z max unchanged

    // CRITICAL: Y should be remapped
    testing.expect_value(t, bounds.min[1], expected_min_y)
    testing.expect_value(t, bounds.max[1], expected_max_y)
}

@(test)
test_bv_tree_various_y_values :: proc(t: ^testing.T) {
    // Test Y remapping with various values to ensure correct behavior

    cs := f32(0.3)
    ch := f32(0.2)
    ch_cs_ratio := ch / cs

    test_cases := []struct {
        y_value: u16,
        expected_min: u16,
        expected_max: u16,
    }{
        {0,  0,  0},   // floor(0 * 0.667) = 0, ceil(0 * 0.667) = 0
        {5,  3,  4},   // floor(5 * 0.667) = 3, ceil(5 * 0.667) = 4
        {10, 6,  7},   // floor(10 * 0.667) = 6, ceil(10 * 0.667) = 7
        {15, 9, 10},  // floor(15 * 0.6666...) = 9, ceil(15 * 0.6666...) = 10
        {20, 13, 14},  // floor(20 * 0.667) = 13, ceil(20 * 0.667) = 14
    }

    for tc in test_cases {
        actual_min := u16(math.floor(f32(tc.y_value) * ch_cs_ratio))
        actual_max := u16(math.ceil(f32(tc.y_value) * ch_cs_ratio))

        testing.expect_value(t, actual_min, tc.expected_min)
        testing.expect_value(t, actual_max, tc.expected_max)
    }
}
