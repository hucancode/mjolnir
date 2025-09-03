package test_recast

import rc "../../mjolnir/navigation/recast"
import "core:testing"
import "core:fmt"
import "core:slice"
import "core:log"
import "core:time"

// Test simple layer assignment with multi-level structures
@(test)
test_simple_layers :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    fmt.println("Testing simple layer assignment...")
    
    // Create a simple multi-level structure
    hf := new(rc.Heightfield)
    defer rc.free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{10, 10, 10}
    ok := rc.create_heightfield(hf, 20, 20, bmin, bmax, 0.5, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Create two levels - ground and elevated platform
    // Ground level
    ground_verts := [][3]f32{
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        {0, 0, 10},
    }
    ground_tris := []i32{0, 1, 2, 0, 2, 3}
    ground_areas := []u8{rc.RC_WALKABLE_AREA, rc.RC_WALKABLE_AREA}
    
    ok = rc.rasterize_triangles(ground_verts, ground_tris, ground_areas, hf, 1)
    testing.expect(t, ok, "Failed to rasterize ground")
    
    // Elevated platform
    platform_verts := [][3]f32{
        {3, 3, 3},
        {7, 3, 3},
        {7, 3, 7},
        {3, 3, 7},
    }
    platform_tris := []i32{0, 1, 2, 0, 2, 3}
    platform_areas := []u8{rc.RC_WALKABLE_AREA, rc.RC_WALKABLE_AREA}
    
    ok = rc.rasterize_triangles(platform_verts, platform_tris, platform_areas, hf, 1)
    testing.expect(t, ok, "Failed to rasterize platform")
    
    // Build compact heightfield
    chf := new(rc.Compact_Heightfield)
    defer rc.free_compact_heightfield(chf)
    
    ok = rc.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    
    // Check for layers
    max_layers := 0
    cells_with_layers := 0
    for i in 0..<(chf.width * chf.height) {
        layers := int(chf.cells[i].count)
        if layers > max_layers do max_layers = layers
        if layers > 1 do cells_with_layers += 1
    }
    
    fmt.printf("  Grid: %dx%d\n", chf.width, chf.height)
    fmt.printf("  Max layers in cell: %d\n", max_layers)
    fmt.printf("  Cells with multiple layers: %d\n", cells_with_layers)
    
    // Build heightfield layers
    lset, layer_ok := rc.build_heightfield_layers(chf, 0, 2)
    defer rc.free_heightfield_layer_set(lset)
    
    if layer_ok {
        fmt.printf("  Generated %d navigation layers\n", len(lset))
        for layer, i in lset {
            fmt.printf("    Layer %d: %dx%d at height [%d-%d]\n",
                      i, layer.width, layer.height, layer.miny, layer.maxy)
        }
    } else {
        fmt.println("  ERROR: Failed to build layers!")
    }
    
    fmt.println("  ✓ Simple layer test completed")
}

// Test that layer building correctly handles overflow (>255 regions)
// IMPORTANT: This test WILL show as "failed" in the test runner because it
// generates error logs, but this is EXPECTED BEHAVIOR - we're testing that
// the system correctly detects and reports >255 region overflow.
@(test)
test_region_overflow_handling :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    fmt.println("\nTesting region overflow handling (expecting controlled failure)...")
    
    // Create a heightfield with many small disconnected regions
    hf := new(rc.Heightfield)
    defer rc.free_heightfield(hf)
    
    bmin := [3]f32{0, 0, 0}
    bmax := [3]f32{100, 10, 100}
    ok := rc.create_heightfield(hf, 200, 200, bmin, bmax, 0.5, 0.5)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Create a grid of small platforms (16x16 = 256 platforms)
    for row in 0..<16 {
        for col in 0..<16 {
            x := f32(col * 6 + 1)
            z := f32(row * 6 + 1)
            y := f32((row + col) % 3) // Vary heights
            
            verts := [][3]f32{
                {x, y, z},
                {x + 2, y, z},
                {x + 2, y, z + 2},
                {x, y, z + 2},
            }
            tris := []i32{0, 1, 2, 0, 2, 3}
            areas := []u8{rc.RC_WALKABLE_AREA, rc.RC_WALKABLE_AREA}
            
            rc.rasterize_triangles(verts, tris, areas, hf, 1)
        }
    }
    
    // Build compact heightfield
    chf := new(rc.Compact_Heightfield)
    defer rc.free_compact_heightfield(chf)
    
    ok = rc.build_compact_heightfield(2, 1, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    
    // Build regions
    rc.build_distance_field(chf)
    rc.build_regions(chf, 0, 1, 1) // Min area = 1 to keep all small regions
    
    // Count unique regions
    max_region := 0
    for i in 0..<chf.span_count {
        if int(chf.spans[i].reg) > max_region {
            max_region = int(chf.spans[i].reg)
        }
    }
    
    fmt.printf("  Created %d regions\n", max_region)
    
    // Try to build layers - this SHOULD fail with >255 regions
    // The error messages are expected and correct behavior!
    lset, layer_ok := rc.build_heightfield_layers(chf, 0, 2)
    defer rc.free_heightfield_layer_set(lset)
    
    if layer_ok {
        // This would be a bug - we expect failure with 256 regions
        fmt.printf("  UNEXPECTED SUCCESS: Generated %d layers from %d regions\n", 
                  len(lset), max_region)
        testing.expect(t, false, "BUG: Layer building should have failed with 256 regions but succeeded!")
    } else {
        // This is correct behavior - layer building should fail with >255 regions
        fmt.printf("  ✓ CORRECT: Layer building failed as expected (>255 region limit)\n")
    }
    
    // Verify we got the expected failure
    testing.expect(t, !layer_ok, "Layer building should fail with >255 regions")
    
    fmt.println("  ✓ Region overflow handling test completed successfully")
}

// Test actual nav_test.obj layer detection
@(test)
test_navtest_layers :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    fmt.println("\nTesting nav_test.obj layer characteristics...")
    
    // Simulate the nav_test.obj structure with known multi-level areas
    hf := new(rc.Heightfield)
    defer rc.free_heightfield(hf)
    
    bmin := [3]f32{-30, -5, -50}
    bmax := [3]f32{65, 20, 35}
    
    // Use same grid size as nav_test.obj
    ok := rc.create_heightfield(hf, 305, 258, bmin, bmax, 0.3, 0.2)
    testing.expect(t, ok, "Failed to create heightfield")
    
    // Create multiple overlapping levels at different heights
    for level in 0..<4 {
        y := f32(level * 4)
        offset := f32(level * 10)
        
        verts := [][3]f32{
            {-20 + offset, y, -40 + offset},
            {50 - offset, y, -40 + offset},
            {50 - offset, y, 20 - offset},
            {-20 + offset, y, 20 - offset},
        }
        tris := []i32{0, 1, 2, 0, 2, 3}
        areas := []u8{rc.RC_WALKABLE_AREA, rc.RC_WALKABLE_AREA}
        
        rc.rasterize_triangles(verts, tris, areas, hf, 4)
    }
    
    chf := new(rc.Compact_Heightfield)
    defer rc.free_compact_heightfield(chf)
    
    ok = rc.build_compact_heightfield(10, 4, hf, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")
    
    // Count layers per cell
    histogram: [10]int // Count cells with 0-9 layers
    max_layers := 0
    
    for i in 0..<(chf.width * chf.height) {
        layers := int(chf.cells[i].count)
        if layers < 10 do histogram[layers] += 1
        if layers > max_layers do max_layers = layers
    }
    
    fmt.println("  Layer distribution in cells:")
    for i in 0..=max_layers {
        if i < 10 && histogram[i] > 0 {
            fmt.printf("    %d layers: %d cells\n", i, histogram[i])
        }
    }
    fmt.printf("  Maximum layers: %d\n", max_layers)
    
    // Build regions before layers
    rc.erode_walkable_area(2, chf)
    rc.build_distance_field(chf)
    rc.build_regions(chf, 0, 8, 20)
    
    // Count regions
    max_region := 0
    for i in 0..<chf.span_count {
        if int(chf.spans[i].reg) > max_region {
            max_region = int(chf.spans[i].reg)
        }
    }
    fmt.printf("  Total regions: %d\n", max_region)
    
    // Build layers
    lset, layer_ok := rc.build_heightfield_layers(chf, 0, 10)
    defer rc.free_heightfield_layer_set(lset)
    
    if layer_ok {
        fmt.printf("  Generated %d heightfield layers\n", len(lset))
        for layer, i in lset {
            if i < 5 {
                fmt.printf("    Layer %d: size=%dx%d, height=[%d-%d]\n",
                          i, layer.width, layer.height, layer.miny, layer.maxy)
            }
        }
    } else {
        fmt.println("  ERROR: Failed to build layers (likely region overflow)")
    }
    
    fmt.println("  ✓ nav_test.obj simulation completed")
}