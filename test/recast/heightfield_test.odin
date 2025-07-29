package test_recast

import nav_recast "../../mjolnir/navigation/recast"
import recast "../../mjolnir/navigation/recast"
import "core:testing"

@(test)
test_span_bit_operations :: proc(t: ^testing.T) {
    span := recast.Rc_Span{}

    // Test setting and getting smin
    span.smin = 100
    testing.expect_value(t, span.smin, u32(100))

    // Test setting and getting smax
    span.smax = 200
    testing.expect_value(t, span.smax, u32(200))
    testing.expect_value(t, span.smin, u32(100)) // Ensure smin unchanged

    // Test setting and getting area
    span.area = 42
    testing.expect_value(t, span.area, u32(42))
    testing.expect_value(t, span.smin, u32(100)) // Ensure smin unchanged
    testing.expect_value(t, span.smax, u32(200)) // Ensure smax unchanged

    // Test max values
    max_height := u32(nav_recast.RC_SPAN_MAX_HEIGHT)
    span.smin = max_height
    span.smax = max_height
    testing.expect_value(t, span.smin, max_height)
    testing.expect_value(t, span.smax, max_height)

    // Test area max value (6 bits = 63)
    span.area = 63
    testing.expect_value(t, span.area, u32(63))
}

@(test)
test_compact_cell_bit_operations :: proc(t: ^testing.T) {
    cell := recast.Rc_Compact_Cell{}

    // Test setting and getting index
    cell.index = 12345
    testing.expect_value(t, cell.index, u32(12345))

    // Test setting and getting count
    cell.count = 42
    testing.expect_value(t, cell.count, u8(42))
    testing.expect_value(t, cell.index, u32(12345)) // Ensure index unchanged

    // Test max values
    max_index := u32(0x00FFFFFF) // 24 bits
    cell.index = max_index
    testing.expect_value(t, cell.index, max_index)

    max_count := u8(255) // 8 bits
    cell.count = max_count
    testing.expect_value(t, cell.count, max_count)
}

@(test)
test_compact_span_bit_operations :: proc(t: ^testing.T) {
    span := recast.Rc_Compact_Span{}

    // Test y and reg (direct fields)
    span.y = 1000
    span.reg = 500
    testing.expect_value(t, span.y, u16(1000))
    testing.expect_value(t, span.reg, u16(500))

    // Test connection data
    span.con = 0x123456
    testing.expect_value(t, span.con, u32(0x123456))

    // Test height
    span.h = 100
    testing.expect_value(t, span.h, u8(100))
    testing.expect_value(t, span.con, u32(0x123456)) // Ensure con unchanged

    // Test max values
    max_con := u32(0x00FFFFFF) // 24 bits
    span.con = max_con
    testing.expect_value(t, span.con, max_con)

    max_h := u8(255) // 8 bits
    span.h = max_h
    testing.expect_value(t, span.h, max_h)
}

@(test)
test_heightfield_allocation :: proc(t: ^testing.T) {

    // Test allocation
    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    // Test initial state
    testing.expect_value(t, hf.width, i32(0))
    testing.expect_value(t, hf.height, i32(0))
    testing.expect(t, hf.spans == nil, "Spans should be nil initially")
    testing.expect(t, hf.pools == nil, "Pools should be nil initially")
    testing.expect(t, hf.freelist == nil, "Freelist should be nil initially")
}

@(test)
test_heightfield_creation :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    // Test creation with specific parameters
    width := i32(50)
    height := i32(50)
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{100, 20, 100}
    cs := f32(2.0)
    ch := f32(0.5)

    ok := recast.rc_create_heightfield(hf, width, height, bmin, bmax, cs, ch)
    testing.expect(t, ok, "Heightfield creation should succeed")

    // Verify parameters
    testing.expect_value(t, hf.width, width)
    testing.expect_value(t, hf.height, height)
    testing.expect_value(t, hf.cs, cs)
    testing.expect_value(t, hf.ch, ch)
    testing.expect_value(t, hf.bmin.x, bmin.x)
    testing.expect_value(t, hf.bmin.y, bmin.y)
    testing.expect_value(t, hf.bmin.z, bmin.z)
    testing.expect_value(t, hf.bmax.x, bmax.x)
    testing.expect_value(t, hf.bmax.y, bmax.y)
    testing.expect_value(t, hf.bmax.z, bmax.z)

    // Verify spans array
    testing.expect(t, hf.spans != nil, "Spans array should be allocated")
    testing.expect_value(t, len(hf.spans), int(width * height))

    // All spans should be nil initially
    for i in 0..<len(hf.spans) {
        testing.expect(t, hf.spans[i] == nil, "Initial spans should be nil")
    }
}

@(test)
test_compact_heightfield_allocation :: proc(t: ^testing.T) {

    // Test allocation
    chf := recast.rc_alloc_compact_heightfield()
    testing.expect(t, chf != nil, "Compact heightfield allocation should succeed")
    defer recast.rc_free_compact_heightfield(chf)

    // Test initial state
    testing.expect_value(t, chf.width, i32(0))
    testing.expect_value(t, chf.height, i32(0))
    testing.expect_value(t, chf.span_count, i32(0))
    testing.expect(t, chf.cells == nil, "Cells should be nil initially")
    testing.expect(t, chf.spans == nil, "Spans should be nil initially")
    testing.expect(t, chf.dist == nil, "Dist should be nil initially")
    testing.expect(t, chf.areas == nil, "Areas should be nil initially")
}

@(test)
test_heightfield_bounds :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    // Test with various bounds
    test_cases := []struct {
        bmin: [3]f32,
        bmax: [3]f32,
        cs: f32,
        expected_width: i32,
        expected_height: i32,
    }{
        // Simple case
        {{0, 0, 0}, {10, 5, 10}, 1.0, 10, 10},
        // Non-zero origin
        {{10, 0, 10}, {20, 5, 20}, 1.0, 10, 10},
        // Fractional cell size
        {{0, 0, 0}, {10, 5, 10}, 0.5, 20, 20},
        // Large area
        {{0, 0, 0}, {100, 10, 100}, 2.0, 50, 50},
    }

    for tc in test_cases {
        width := i32((tc.bmax.x - tc.bmin.x) / tc.cs)
        height := i32((tc.bmax.z - tc.bmin.z) / tc.cs)

        ok := recast.rc_create_heightfield(hf, width, height, tc.bmin, tc.bmax, tc.cs, 0.5)
        testing.expect(t, ok, "Heightfield creation should succeed")

        testing.expect_value(t, hf.width, tc.expected_width)
        testing.expect_value(t, hf.height, tc.expected_height)

        // Clean up for next test
        if hf.spans != nil {
            delete(hf.spans)
            hf.spans = nil
        }
    }
}

@(test)
test_heightfield_edge_cases :: proc(t: ^testing.T) {

    hf := recast.rc_alloc_heightfield()
    testing.expect(t, hf != nil, "Heightfield allocation should succeed")
    defer recast.rc_free_heightfield(hf)

    // Test minimum size (1x1)
    ok := recast.rc_create_heightfield(hf, 1, 1, {0,0,0}, {1,1,1}, 1.0, 1.0)
    testing.expect(t, ok, "1x1 heightfield should succeed")
    testing.expect_value(t, len(hf.spans), 1)

    // Clean up
    if hf.spans != nil {
        delete(hf.spans)
        hf.spans = nil
    }

    // Test zero width/height (should fail or handle gracefully)
    ok = recast.rc_create_heightfield(hf, 0, 0, {0,0,0}, {1,1,1}, 1.0, 1.0)
    if ok {
        testing.expect_value(t, len(hf.spans), 0)
    }
}
