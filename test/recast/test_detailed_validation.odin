#+feature dynamic-literals
package test_recast

import "core:testing"
import "core:log"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:math"
import nav "../../mjolnir/navigation/recast"

// Detailed test comparing specific Recast functions with expected C++ outputs
@(test)
test_basic_span_merging :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Span Merging ===")

    // Create a small heightfield for testing
    hf := new(nav.Heightfield)
    defer nav.free_heightfield(hf)

    if !nav.create_heightfield(hf, 10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5) {
        testing.fail(t)
        return
    }

    // Test 1: Add non-overlapping spans
    ok1 := nav.add_span(hf, 5, 5, 10, 20, nav.RC_WALKABLE_AREA, 1)
    ok2 := nav.add_span(hf, 5, 5, 30, 40, nav.RC_WALKABLE_AREA, 1)

    testing.expect(t, ok1, "Failed to add first span")
    testing.expect(t, ok2, "Failed to add second span")

    // Count spans in column
    count := 0
    s := hf.spans[5 + 5 * hf.width]
    for s != nil {
        count += 1
        log.infof("  Span %d: [%d, %d] area=%d", count, s.smin, s.smax, s.area)
        s = s.next
    }
    testing.expect_value(t, count, 2)

    // Test 2: Add overlapping spans that should merge
    hf2 := new(nav.Heightfield)
    defer nav.free_heightfield(hf2)

    if !nav.create_heightfield(hf2, 10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5) {
        testing.fail(t)
        return
    }

    ok3 := nav.add_span(hf2, 3, 3, 10, 25, nav.RC_WALKABLE_AREA, 1)
    ok4 := nav.add_span(hf2, 3, 3, 20, 30, nav.RC_WALKABLE_AREA, 1)

    testing.expect(t, ok3, "Failed to add overlapping span 1")
    testing.expect(t, ok4, "Failed to add overlapping span 2")

    // Should have merged into one span
    count2 := 0
    s2 := hf2.spans[3 + 3 * hf2.width]
    for s2 != nil {
        count2 += 1
        log.infof("  Merged span %d: [%d, %d] area=%d", count2, s2.smin, s2.smax, s2.area)
        s2 = s2.next
    }
    testing.expect_value(t, count2, 1)

    log.info("✓ Span merging test passed")
}

@(test)
test_triangle_rasterization :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Triangle Rasterization ===")

    hf := new(nav.Heightfield)
    defer nav.free_heightfield(hf)

    if !nav.create_heightfield(hf, 10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5) {
        testing.fail(t)
        return
    }

    // Test single triangle rasterization
    v0 := [3]f32{2, 1, 2}
    v1 := [3]f32{8, 1, 2}
    v2 := [3]f32{5, 1, 8}

    ok := nav.rasterize_triangle(v0, v1, v2, nav.RC_WALKABLE_AREA, hf, 1)
    testing.expect(t, ok, "Failed to rasterize triangle")

    // Count total spans created
    total_spans := 0
    for z in 0..<hf.height {
        for x in 0..<hf.width {
            s := hf.spans[x + z * hf.width]
            for s != nil {
                total_spans += 1
                s = s.next
            }
        }
    }

    log.infof("Triangle rasterization created %d spans", total_spans)
    testing.expect(t, total_spans > 0, "No spans created from triangle")

    // Test degenerate triangle (should handle gracefully)
    v3 := [3]f32{0, 0, 0}
    v4 := [3]f32{1, 0, 0}
    v5 := [3]f32{2, 0, 0}  // Collinear points

    ok2 := nav.rasterize_triangle(v3, v4, v5, nav.RC_WALKABLE_AREA, hf, 1)
    testing.expect(t, ok2, "Failed to handle degenerate triangle")

    log.info("✓ Triangle rasterization test passed")
}

@(test)
test_region_generation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Region Generation ===")

    // Create a more complex test scene
    vertices := [][3]f32{
        // Ground plane with hole
        {0, 0, 0}, {20, 0, 0}, {20, 0, 20}, {0, 0, 20},
        // Obstacle in middle
        {8, 0, 8}, {12, 0, 8}, {12, 3, 8}, {8, 3, 8},
        {8, 0, 12}, {12, 0, 12}, {12, 3, 12}, {8, 3, 12},
    }

    indices := []i32{
        0, 1, 2,
        0, 2, 3,
        // Obstacle faces
        4, 5, 6,
        4, 6, 7,
        5, 9, 10,
        5, 10, 6,
        9, 8, 11,
        9, 11, 10,
        8, 4, 7,
        8, 7, 11,
    }

    areas := make([]u8, 10)
    defer delete(areas)
    for i in 0..<10 {
        areas[i] = nav.RC_WALKABLE_AREA
    }

    cfg := nav.Config{
        cs = 0.5,
        ch = 0.2,
        walkable_slope_angle = 45.0,
        walkable_height = 10,
        walkable_climb = 4,
        walkable_radius = 2,
        min_region_area = 16,
        merge_region_area = 40,
    }

    cfg.bmin, cfg.bmax = nav.calc_bounds(vertices)
    cfg.width, cfg.height = nav.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)

    // Build heightfield
    hf := new(nav.Heightfield)
    defer nav.free_heightfield(hf)

    if !nav.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch) {
        testing.fail(t)
        return
    }

    // Mark and rasterize
    nav.mark_walkable_triangles(cfg.walkable_slope_angle, vertices, indices, areas)

    if !nav.rasterize_triangles(vertices, indices, areas, hf, cfg.walkable_climb) {
        testing.fail(t)
        return
    }

    // Filter
    nav.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    nav.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    nav.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)

    // Build compact heightfield
    chf := new(nav.Compact_Heightfield)
    defer nav.free_compact_heightfield(chf)

    if !nav.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf) {
        testing.fail(t)
        return
    }

    // Erode and build distance field
    if !nav.erode_walkable_area(cfg.walkable_radius, chf) {
        testing.fail(t)
        return
    }

    if !nav.build_distance_field(chf) {
        testing.fail(t)
        return
    }

    // Build regions
    if !nav.build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area) {
        log.error("Failed to build regions")
        testing.fail(t)
        return
    }

    log.infof("Generated %d regions", chf.max_regions)

    // Count spans in each region
    region_counts := make([]int, chf.max_regions + 1)
    defer delete(region_counts)

    for i in 0..<chf.span_count {
        reg := chf.spans[i].reg
        if reg > 0 && reg < u16(len(region_counts)) {
            region_counts[reg] += 1
        }
    }

    for i in 1..=int(chf.max_regions) {
        if region_counts[i] > 0 {
            log.infof("  Region %d: %d spans", i, region_counts[i])
        }
    }

    testing.expect(t, chf.max_regions > 0, "No regions generated")

    log.info("✓ Region generation test passed")
}

@(test)
test_basic_contour_simplification :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Basic Contour Simplification ===")

    // Create a raw contour for simplification
    raw_verts := [][4]i32{
        {0, 0, 0, 0},
        {10, 0, 0, 0},
        {10, 0, 1, 0},  // Small deviation
        {10, 0, 10, 0},
        {9, 0, 10, 0},  // Small deviation
        {0, 0, 10, 0},
        {0, 0, 5, 0},   // Mid-point
    }

    simplified := make([dynamic][4]i32)
    defer delete(simplified)

    // Simplify with different error tolerances
    nav.simplify_contour(raw_verts, &simplified, 0.5, 1.0, 12)

    log.infof("Original vertices: %d", len(raw_verts))
    log.infof("Simplified vertices: %d", len(simplified))

    for v, i in simplified {
        log.infof("  Simplified vertex %d: %v", i, v)
    }

    // Should have removed small deviations
    testing.expect(t, len(simplified) < len(raw_verts), "Simplification should reduce vertex count")
    testing.expect(t, len(simplified) >= 3, "Simplified contour should have at least 3 vertices")

    // Test with no simplification (max_error = 0)
    no_simp := make([dynamic][4]i32)
    defer delete(no_simp)

    nav.simplify_contour(raw_verts, &no_simp, 0.0, 1.0, 12)
    testing.expect_value(t, len(no_simp), len(raw_verts))

    log.info("✓ Contour simplification test passed")
}

@(test)
test_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Edge Cases ===")

    // Test 1: Empty mesh
    {
        vertices := [][3]f32{}
        indices := []i32{}
        areas := []u8{}

        cfg := nav.Config{
            cs = 0.3,
            ch = 0.2,
            walkable_slope_angle = 45.0,
        }

        pmesh, dmesh, ok := nav.build_navmesh(vertices, indices, areas, cfg)
        testing.expect(t, !ok, "Empty mesh should fail gracefully")

        if pmesh != nil do nav.free_poly_mesh(pmesh)
        if dmesh != nil do nav.free_poly_mesh_detail(dmesh)
    }

    // Test 2: Single triangle
    {
        vertices := [][3]f32{
            {0, 0, 0},
            {1, 0, 0},
            {0.5, 0, 1},
        }
        indices := []i32{0, 1, 2}
        areas := []u8{nav.RC_WALKABLE_AREA}

        cfg := nav.Config{
            cs = 0.1,
            ch = 0.1,
            walkable_slope_angle = 45.0,
            walkable_height = 10,
            walkable_climb = 4,
            walkable_radius = 0,
            min_region_area = 1,
            merge_region_area = 2,
            max_verts_per_poly = 6,
            detail_sample_dist = 1.0,
            detail_sample_max_error = 0.1,
        }

        pmesh, dmesh, ok := nav.build_navmesh(vertices, indices, areas, cfg)

        if ok {
            log.infof("Single triangle produced %d polygons", pmesh.npolys)
            testing.expect(t, pmesh.npolys > 0, "Single triangle should produce at least one polygon")
        }

        if pmesh != nil do nav.free_poly_mesh(pmesh)
        if dmesh != nil do nav.free_poly_mesh_detail(dmesh)
    }

    // Test 3: Very large mesh bounds
    {
        vertices := [][3]f32{
            {-1000, 0, -1000},
            {1000, 0, -1000},
            {1000, 0, 1000},
            {-1000, 0, 1000},
        }
        indices := []i32{0, 1, 2, 0, 2, 3}
        areas := []u8{nav.RC_WALKABLE_AREA, nav.RC_WALKABLE_AREA}

        cfg := nav.Config{
            cs = 10.0,  // Large cell size for huge mesh
            ch = 1.0,
            walkable_slope_angle = 45.0,
            walkable_height = 10,
            walkable_climb = 4,
            walkable_radius = 2,
            min_region_area = 8,
            merge_region_area = 20,
            max_verts_per_poly = 6,
            detail_sample_dist = 50.0,
            detail_sample_max_error = 5.0,
        }

        pmesh, dmesh, ok := nav.build_navmesh(vertices, indices, areas, cfg)

        if ok {
            log.infof("Large mesh produced %d polygons", pmesh.npolys)
            testing.expect(t, pmesh.npolys > 0, "Large mesh should produce polygons")
        }

        if pmesh != nil do nav.free_poly_mesh(pmesh)
        if dmesh != nil do nav.free_poly_mesh_detail(dmesh)
    }

    log.info("✓ Edge cases test passed")
}

@(test)
test_filter_operations :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing Filter Operations ===")

    hf := new(nav.Heightfield)
    defer nav.free_heightfield(hf)

    if !nav.create_heightfield(hf, 10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5) {
        testing.fail(t)
        return
    }

    // Create a test scenario with various spans
    // Column with multiple spans at different heights
    nav.add_span(hf, 5, 5, 0, 10, nav.RC_WALKABLE_AREA, 1)   // Ground
    nav.add_span(hf, 5, 5, 12, 14, nav.RC_WALKABLE_AREA, 1)  // Low overhang
    nav.add_span(hf, 5, 5, 20, 30, nav.RC_WALKABLE_AREA, 1)  // Platform

    // Column with ledge
    nav.add_span(hf, 6, 5, 0, 10, nav.RC_WALKABLE_AREA, 1)
    nav.add_span(hf, 6, 5, 11, 12, nav.RC_WALKABLE_AREA, 1)  // Thin ledge

    initial_count := 0
    for z in 0..<hf.height {
        for x in 0..<hf.width {
            s := hf.spans[x + z * hf.width]
            for s != nil {
                if s.area != nav.RC_NULL_AREA {
                    initial_count += 1
                }
                s = s.next
            }
        }
    }

    log.infof("Initial walkable spans: %d", initial_count)

    // Apply filters
    nav.filter_low_hanging_walkable_obstacles(4, hf)
    nav.filter_ledge_spans(10, 4, hf)
    nav.filter_walkable_low_height_spans(10, hf)

    filtered_count := 0
    for z in 0..<hf.height {
        for x in 0..<hf.width {
            s := hf.spans[x + z * hf.width]
            for s != nil {
                if s.area != nav.RC_NULL_AREA {
                    filtered_count += 1
                }
                s = s.next
            }
        }
    }

    log.infof("Filtered walkable spans: %d", filtered_count)

    testing.expect(t, filtered_count <= initial_count, "Filtering should not increase span count")

    log.info("✓ Filter operations test passed")
}
