package test_recast

import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"

// NOTE: Full pipeline test moved to integration_test.odin to avoid duplication

// NOTE: Basic heightfield creation tests moved to heightfield_test.odin to avoid duplication

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
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{1, 1, 1}
    ok := recast.create_heightfield(hf, 1, 1, bmin, bmax, 1.0, 0.1)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add a span manually
    ok = recast.add_span(hf, 0, 0, 0, 10, recast.RC_WALKABLE_AREA, 1)
    testing.expect(t, ok, "Failed to add span")

    // Build compact heightfield
    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    testing.expect_value(t, chf.span_count, i32(1))
}
