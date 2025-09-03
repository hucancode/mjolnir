package test_detour

import "core:testing"
import "core:math"
import "core:time"
import "core:log"
import "../../mjolnir/navigation/recast"
import "../../mjolnir/navigation/detour"

@(test)
test_tile_coordinate_calculation_robustness :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test valid cases first
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 10.0,
            tile_height = 10.0,
        }

        // Basic positive coordinates
        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {5, 0, 5})
        testing.expect_value(t, recast.status_succeeded(status), true)
        testing.expect_value(t, tx, 0)
        testing.expect_value(t, ty, 0)

        // Coordinates on tile boundaries
        tx, ty, status = detour.calc_tile_loc(&nav_mesh, {10, 0, 10})
        testing.expect_value(t, recast.status_succeeded(status), true)
        testing.expect_value(t, tx, 1)
        testing.expect_value(t, ty, 1)

        // Negative coordinates (should use floor division)
        tx, ty, status = detour.calc_tile_loc(&nav_mesh, {-5, 0, -5})
        testing.expect_value(t, recast.status_succeeded(status), true)
        testing.expect_value(t, tx, -1)  // Floor(-0.5) = -1
        testing.expect_value(t, ty, -1)

        // Large but valid coordinates
        tx, ty, status = detour.calc_tile_loc(&nav_mesh, {100000, 0, 100000})
        testing.expect_value(t, recast.status_succeeded(status), true)
        testing.expect_value(t, tx, 10000)
        testing.expect_value(t, ty, 10000)
    }

    // Test error cases - null pointer
    {
        tx, ty, status := detour.calc_tile_loc(nil, {0, 0, 0})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)
        testing.expect_value(t, tx, 0)
        testing.expect_value(t, ty, 0)
    }

    // Test error cases - zero tile dimensions
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 0.0,
            tile_height = 10.0,
        }

        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {5, 0, 5})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)
    }

    // Test error cases - negative tile dimensions
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = -10.0,
            tile_height = 10.0,
        }

        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {5, 0, 5})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)
    }

    // Test error cases - extremely small tile dimensions
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 1e-7,  // Smaller than MIN_TILE_DIMENSION
            tile_height = 10.0,
        }

        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {5, 0, 5})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)
    }

    // Test error cases - infinite position values
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 10.0,
            tile_height = 10.0,
        }

        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {math.F32_MAX, 0, 0})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)

        // Test with extremely large values that should be caught
        tx, ty, status = detour.calc_tile_loc(&nav_mesh, {1e25, 0, 0})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)
    }

    // Test error cases - overflow protection
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 1e-6,  // Very small tiles
            tile_height = 1e-6,
        }

        // This would cause very large tile coordinates
        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {1e6, 0, 1e6})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)
    }

    // Test error cases - extremely large tile indices
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 1.0,
            tile_height = 1.0,
        }

        // Coordinates that would result in tile indices beyond reasonable limits
        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {2_000_000, 0, 2_000_000})
        testing.expect_value(t, recast.status_failed(status), true)
        testing.expect_value(t, recast.Status_Flag.Invalid_Param in status, true)
    }

    // Test edge case - coordinates exactly at boundary conditions
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 10.0,
            tile_height = 10.0,
        }

        // Test exactly at maximum reasonable tile index
        max_coord := f32(999_999 * 10)  // Just under the limit
        tx, ty, status := detour.calc_tile_loc(&nav_mesh, {max_coord, 0, max_coord})
        testing.expect_value(t, recast.status_succeeded(status), true)
        testing.expect_value(t, tx, 999_999)
        testing.expect_value(t, ty, 999_999)
    }
}

@(test)
test_tile_coordinate_simple_version :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test that simple version returns (0, 0) for invalid inputs
    {
        // Null pointer should return (0, 0)
        tx, ty := detour.calc_tile_loc_simple(nil, {0, 0, 0})
        testing.expect_value(t, tx, 0)
        testing.expect_value(t, ty, 0)

        // Invalid tile dimensions should return (0, 0)
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 0.0,
            tile_height = 10.0,
        }

        tx, ty = detour.calc_tile_loc_simple(&nav_mesh, {5, 0, 5})
        testing.expect_value(t, tx, 0)
        testing.expect_value(t, ty, 0)
    }

    // Test that simple version works for valid inputs
    {
        nav_mesh := detour.Nav_Mesh{
            orig = {0, 0, 0},
            tile_width = 10.0,
            tile_height = 10.0,
        }

        tx, ty := detour.calc_tile_loc_simple(&nav_mesh, {25, 0, 35})
        testing.expect_value(t, tx, 2)
        testing.expect_value(t, ty, 3)
    }
}

@(test)
test_tile_coordinate_negative_handling :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test that negative coordinates use floor division correctly
    nav_mesh := detour.Nav_Mesh{
        orig = {0, 0, 0},
        tile_width = 10.0,
        tile_height = 10.0,
    }

    test_cases := []struct{
        pos: [3]f32,
        expected_tx: i32,
        expected_ty: i32,
    }{
        // Positive coordinates
        {{5, 0, 5}, 0, 0},
        {{15, 0, 25}, 1, 2},

        // Exactly on boundaries
        {{10, 0, 10}, 1, 1},
        {{0, 0, 0}, 0, 0},

        // Negative coordinates - should use floor division
        {{-5, 0, -5}, -1, -1},      // Floor(-0.5) = -1
        {{-10, 0, -10}, -1, -1},    // Floor(-1.0) = -1
        {{-15, 0, -15}, -2, -2},    // Floor(-1.5) = -2

        // Mixed positive/negative
        {{5, 0, -5}, 0, -1},
        {{-5, 0, 5}, -1, 0},
    }

    for test_case in test_cases {
        tx, ty, status := detour.calc_tile_loc(&nav_mesh, test_case.pos)
        testing.expectf(t, recast.status_succeeded(status),
                       "Expected success for position %v", test_case.pos)
        testing.expectf(t, tx == test_case.expected_tx,
                       "Expected tx=%d, got %d for position %v",
                       test_case.expected_tx, tx, test_case.pos)
        testing.expectf(t, ty == test_case.expected_ty,
                       "Expected ty=%d, got %d for position %v",
                       test_case.expected_ty, ty, test_case.pos)
    }
}

@(test)
test_tile_coordinate_precision_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test with very small but valid tile dimensions
    nav_mesh := detour.Nav_Mesh{
        orig = {0, 0, 0},
        tile_width = 1e-5,   // Just above MIN_TILE_DIMENSION
        tile_height = 1e-5,
    }

    // Test with small coordinates
    tx, ty, status := detour.calc_tile_loc(&nav_mesh, {1e-4, 0, 1e-4})
    testing.expect_value(t, recast.status_succeeded(status), true)
    testing.expect_value(t, tx, 10)  // 1e-4 / 1e-5 = 10
    testing.expect_value(t, ty, 10)

    // Test with coordinates that would be close to overflow boundary
    nav_mesh2 := detour.Nav_Mesh{
        orig = {0, 0, 0},
        tile_width = 1.0,
        tile_height = 1.0,
    }

    // Test coordinates just under the reasonable tile index limit
    // Use MAX_REASONABLE_TILE_INDEX (1M) as reference, with tile_width=1.0 this maps directly
    reasonable_coord := f32(999_999)  // Just under the 1M tile limit
    tx, ty, status = detour.calc_tile_loc(&nav_mesh2, {reasonable_coord, 0, reasonable_coord})
    testing.expect_value(t, recast.status_succeeded(status), true)
    testing.expect_value(t, tx, 999_999)
    testing.expect_value(t, ty, 999_999)
}
