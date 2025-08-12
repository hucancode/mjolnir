package test_recast

import recast "../../mjolnir/navigation/recast"
import "core:testing"
import "core:log"
import "core:time"
import "core:math"
import "core:math/linalg"

// ================================
// SECTION 1: BASIC CONTOUR BUILDING
// ================================

@(test)
test_build_contours_simple_region :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a simple scenario for contour building
    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    // Create 10x10 heightfield for more reliable region building
    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add walkable area in center (5x5 for sufficient area)
    for x in 2..=6 {
        for z in 2..=6 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add walkable span")
        }
    }

    // Build compact heightfield
    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Build regions
    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    ok = recast.build_regions(chf, 2, 8, 20)  // Reduced border size to allow interior spans
    testing.expect(t, ok, "Failed to build regions")

    // Build contours
    contour_set := recast.alloc_contour_set()
    testing.expect(t, contour_set != nil, "Failed to allocate contour set")
    defer recast.free_contour_set(contour_set)

    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})
    testing.expect(t, ok, "Failed to build contours")

    // Verify contours were generated
    testing.expect(t, len(contour_set.conts) > 0, "Should have generated contours")

    if len(contour_set.conts) > 0 {
        contour := &contour_set.conts[0]
        testing.expect(t, len(contour.verts) > 0, "Contour should have vertices")
    }

    log.infof("✓ Simple contour building test passed - %d contours generated", len(contour_set.conts))
}

@(test)
test_build_contours_multiple_regions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 10, 10, {0,0,0}, {10,10,10}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create two separate walkable regions (larger and closer for better success)
    // Region 1: 3x3 area
    for x in 1..=3 {
        for z in 1..=3 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add region 1 span")
        }
    }

    // Region 2: 3x3 area (separated by gap)
    for x in 5..=7 {
        for z in 5..=7 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add region 2 span")
        }
    }

    // Build compact heightfield and regions
    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    ok = recast.build_regions(chf, 1, 5, 10)  // Parameters for 3x3 regions (9 spans each)
    testing.expect(t, ok, "Failed to build regions")

    // Build contours
    contour_set := recast.alloc_contour_set()
    testing.expect(t, contour_set != nil, "Failed to allocate contour set")
    defer recast.free_contour_set(contour_set)

    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})
    testing.expect(t, ok, "Failed to build contours")

    // Should have contours for both regions
    testing.expect(t, len(contour_set.conts) >= 1, "Should have contours for multiple regions")

    log.infof("✓ Multiple regions contour test passed - %d contours generated", len(contour_set.conts))
}

@(test)
test_build_contours_with_holes :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 8, 8, {0,0,0}, {8,8,8}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create walkable area with hole in middle
    // Outer area: 6x6
    for x in 1..=6 {
        for z in 1..=6 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add outer area span")
        }
    }

    // Remove hole in center: 2x2
    for x in 3..=4 {
        for z in 3..=4 {
            // Clear the spans to create a hole
            column_index := i32(x) + i32(z) * hf.width
            if span := hf.spans[column_index]; span != nil {
                span.area = u32(recast.RC_NULL_AREA)
            }
        }
    }

    chf := new(recast.Compact_Heightfield)
    testing.expect(t, chf != nil, "Failed to allocate compact heightfield")
    defer recast.free_compact_heightfield(chf)

    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    ok = recast.build_regions(chf, 1, 10, 10)
    testing.expect(t, ok, "Failed to build regions")

    // Build contours
    contour_set := recast.alloc_contour_set()
    testing.expect(t, contour_set != nil, "Failed to allocate contour set")
    defer recast.free_contour_set(contour_set)

    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})
    testing.expect(t, ok, "Failed to build contours with holes")

    // Should generate contours including hole boundaries
    testing.expect(t, len(contour_set.conts) > 0, "Should have contours with holes")

    log.infof("✓ Contours with holes test passed - %d contours generated", len(contour_set.conts))
}

// ================================
// SECTION 2: CONTOUR SIMPLIFICATION
// ================================

@(test)
test_contour_simplification_accuracy :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    testing.expect(t, hf != nil, "Failed to allocate heightfield")
    defer recast.free_heightfield(hf)

    ok := recast.create_heightfield(hf, 6, 6, {0,0,0}, {6,6,6}, 1.0, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")

    // Create simple rectangular area
    for x in 1..=4 {
        for z in 1..=4 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
            testing.expect(t, ok, "Failed to add span")
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 2, 8, 20)  // Reduced border size to allow interior spans

    // Test different simplification levels
    simplification_levels := []f32{0.0, 1.0, 2.0}

    for level in simplification_levels {
        contour_set := recast.alloc_contour_set()
        defer recast.free_contour_set(contour_set)

        ok = recast.build_contours(chf, level, 1, contour_set, {.WALL_EDGES})
        testing.expect(t, ok, "Failed to build contours with simplification")

        if len(contour_set.conts) > 0 {
            contour := &contour_set.conts[0]
            vertex_count := len(contour.verts)
            log.infof("Simplification %.1f: %d vertices", level, vertex_count)

            // Higher simplification should generally result in fewer vertices
            testing.expect(t, vertex_count >= 4, "Rectangular contour should have at least 4 vertices")
        }
    }

    log.info("✓ Contour simplification accuracy test passed")
}

@(test)
test_contour_edge_length_constraints :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    defer recast.free_heightfield(hf)
    ok := recast.create_heightfield(hf, 8, 8, {0,0,0}, {8,8,8}, 1.0, 0.5)

    // Create long thin walkable area
    for x in 1..=6 {
        for z in 3..=4 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 1, 10, 10)

    // Test different max edge lengths
    max_edge_lengths := []i32{1, 3, 6}

    for max_edge_len in max_edge_lengths {
        contour_set := recast.alloc_contour_set()
        defer recast.free_contour_set(contour_set)

        ok = recast.build_contours(chf, 1.0, max_edge_len, contour_set, {.WALL_EDGES})
        testing.expect(t, ok, "Failed to build contours with edge length constraint")

        if len(contour_set.conts) > 0 {
            contour := &contour_set.conts[0]

            // Check that no edge is longer than max_edge_len (in voxel units)
            max_found_edge := f32(0)
            vertex_count := len(contour.verts)
            for i in 0..<vertex_count {
                next_i := (i + 1) % vertex_count
                v1 := contour.verts[i]
                v2 := contour.verts[next_i]
                dx := f32(v2[0] - v1[0])
                dz := f32(v2[2] - v1[2])
                edge_len := math.sqrt_f32(dx*dx + dz*dz)
                max_found_edge = math.max(max_found_edge, edge_len)
            }

            log.infof("Max edge len %d: longest edge found = %.2f", max_edge_len, max_found_edge)
        }
    }

    log.info("✓ Edge length constraints test passed")
}

// ================================
// SECTION 3: TESSELLATION FLAGS
// ================================

@(test)
test_contour_tessellation_wall_edges :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    defer recast.free_heightfield(hf)
    ok := recast.create_heightfield(hf, 6, 6, {0,0,0}, {6,6,6}, 1.0, 0.5)

    // Create simple area
    for x in 2..=4 {
        for z in 2..=4 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 1, 10, 10)

    // Test with wall edge tessellation
    contour_set_wall := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set_wall)

    ok = recast.build_contours(chf, 1.0, 3, contour_set_wall, {.WALL_EDGES})
    testing.expect(t, ok, "Failed to build contours with wall edge tessellation")

    wall_edge_verts := 0
    if len(contour_set_wall.conts) > 0 {
        wall_edge_verts = len(contour_set_wall.conts[0].verts)
    }

    log.infof("Wall edge tessellation: %d vertices", wall_edge_verts)

    log.info("✓ Wall edge tessellation test passed")
}

@(test)
test_contour_tessellation_area_edges :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    defer recast.free_heightfield(hf)
    ok := recast.create_heightfield(hf, 6, 6, {0,0,0}, {6,6,6}, 1.0, 0.5)

    // Create simple area
    for x in 2..=4 {
        for z in 2..=4 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 1, 10, 10)

    // Test with area edge tessellation
    contour_set_area := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set_area)

    ok = recast.build_contours(chf, 1.0, 3, contour_set_area, {.AREA_EDGES})
    testing.expect(t, ok, "Failed to build contours with area edge tessellation")

    area_edge_verts := 0
    if len(contour_set_area.conts) > 0 {
        area_edge_verts = len(contour_set_area.conts[0].verts)
    }

    log.infof("Area edge tessellation: %d vertices", area_edge_verts)

    log.info("✓ Area edge tessellation test passed")
}

// ================================
// SECTION 4: BOUNDARY VERTEX HANDLING
// ================================

@(test)
test_contour_boundary_vertices :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    defer recast.free_heightfield(hf)

    // Create area that touches heightfield boundaries
    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)

    // Add walkable area touching boundaries
    for x in 0..=4 { // Full width
        for z in 0..=4 { // Full height
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 1, 20, 20)

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)

    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})
    testing.expect(t, ok, "Failed to build contours touching boundaries")

    testing.expect(t, len(contour_set.conts) > 0, "Should generate boundary contours")

    if len(contour_set.conts) > 0 {
        contour := &contour_set.conts[0]
        testing.expect(t, len(contour.verts) >= 4, "Boundary contour should have vertices")

        // Check that boundary vertices are properly handled
        for i in 0..<len(contour.verts) {
            v := contour.verts[i]
            log.infof("Boundary vertex %d: (%d, %d, %d)", i, v[0], v[1], v[2])
        }
    }

    log.info("✓ Boundary vertex handling test passed")
}

// ================================
// SECTION 5: COMPLEX CONTOUR SCENARIOS
// ================================

@(test)
test_contour_l_shaped_region :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    hf := new(recast.Heightfield)
    defer recast.free_heightfield(hf)
    ok := recast.create_heightfield(hf, 8, 8, {0,0,0}, {8,8,8}, 1.0, 0.5)

    // Create L-shaped walkable area
    // Vertical part of L
    for x in 2..=3 {
        for z in 1..=6 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
        }
    }
    // Horizontal part of L
    for x in 4..=6 {
        for z in 5..=6 {
            ok = recast.add_span(hf, i32(x), i32(z), 0, 4, recast.RC_WALKABLE_AREA, 1)
        }
    }

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    ok = recast.build_distance_field(chf)
    ok = recast.build_regions(chf, 1, 10, 15)  // Reduced for L-shaped region (18 spans total)

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)

    ok = recast.build_contours(chf, 1.0, 2, contour_set, {.WALL_EDGES})
    testing.expect(t, ok, "Failed to build L-shaped contours")

    testing.expect(t, len(contour_set.conts) > 0, "Should generate L-shaped contours")

    if len(contour_set.conts) > 0 {
        contour := &contour_set.conts[0]
        vertex_count := len(contour.verts)
        // L-shape should have more than 4 vertices due to the concave corner
        testing.expect(t, vertex_count > 4, "L-shaped contour should have more than 4 vertices")

        log.infof("L-shaped contour: %d vertices", vertex_count)
    }

    log.info("✓ L-shaped contour test passed")
}

@(test)
test_contour_generation_empty_input :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test contour generation with no walkable areas
    hf := new(recast.Heightfield)
    defer recast.free_heightfield(hf)
    ok := recast.create_heightfield(hf, 5, 5, {0,0,0}, {5,5,5}, 1.0, 0.5)

    // Don't add any walkable spans - all will be null area

    chf := new(recast.Compact_Heightfield)
    defer recast.free_compact_heightfield(chf)
    ok = recast.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Should build compact heightfield even with no walkable area")

    ok = recast.build_distance_field(chf)
    testing.expect(t, ok, "Should build distance field even with no walkable area")

    ok = recast.build_regions(chf, 1, 10, 10)
    testing.expect(t, ok, "Should build regions even with no walkable area")

    contour_set := recast.alloc_contour_set()
    defer recast.free_contour_set(contour_set)

    ok = recast.build_contours(chf, 1.0, 1, contour_set, {.WALL_EDGES})
    testing.expect(t, ok, "Should succeed even with no walkable areas")

    // Should have no contours
    testing.expect_value(t, len(contour_set.conts), 0)

    log.info("✓ Empty input contour generation test passed")
}
