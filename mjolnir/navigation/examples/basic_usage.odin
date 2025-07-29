package navigation_examples

// This file demonstrates basic usage of the Recast navigation mesh API

import nav_recast "../recast"
import recast "../recast"
import "core:log"

// Example 1: Simple navigation mesh generation
example_simple_navmesh :: proc() -> bool {
    log.info("=== Example 1: Simple Navigation Mesh ===")
    
    // Define a simple floor geometry
    vertices := []f32{
        0, 0, 0,     // Bottom-left
        20, 0, 0,    // Bottom-right  
        20, 0, 20,   // Top-right
        0, 0, 20,    // Top-left
    }
    
    indices := []i32{
        0, 1, 2,     // First triangle
        0, 2, 3,     // Second triangle
    }
    
    // Use the quick build function for simplicity
    pmesh, dmesh, ok := recast.quick_build_navmesh(vertices, indices, 0.3)
    if !ok {
        log.error("Failed to build simple navigation mesh")
        return false
    }
    
    defer {
        recast.rc_free_poly_mesh(pmesh)
        recast.rc_free_poly_mesh_detail(dmesh)
    }
    
    log.infof("Built navigation mesh with %d polygons and %d vertices", 
              pmesh.npolys, pmesh.nverts)
    
    return true
}

// Example 2: Using configuration presets
example_config_presets :: proc() -> bool {
    log.info("=== Example 2: Configuration Presets ===")
    
    // Same geometry as before
    vertices := []f32{
        0, 0, 0, 10, 0, 0, 10, 0, 10, 0, 0, 10,
    }
    indices := []i32{0, 1, 2, 0, 2, 3}
    areas := []u8{nav_recast.RC_WALKABLE_AREA, nav_recast.RC_WALKABLE_AREA}
    
    geometry, ok := recast.create_geometry_input(vertices, indices, areas)
    if !ok {
        log.error("Failed to create geometry input")
        return false
    }
    
    // Try different quality presets
    presets := []recast.Config_Preset{.Fast, .Balanced, .High_Quality}
    
    for preset in presets {
        config := recast.create_config_from_preset(preset)
        
        result := recast.build_navmesh(&geometry, config)
        if !result.success {
            log.errorf("Failed to build with preset %v: %s", preset, result.error_message)
            continue
        }
        
        defer recast.free_build_result(&result)
        
        log.infof("Preset %v: %d polygons, %.2f ms build time", 
                  preset, result.polygon_mesh.npolys, result.total_time_ms)
    }
    
    return true
}

// Example 3: Step-by-step building with builder pattern
example_builder_pattern :: proc() -> bool {
    log.info("=== Example 3: Builder Pattern ===")
    
    // Create a slightly larger floor
    vertices := []f32{
        0, 0, 0,
        30, 0, 0,
        30, 0, 30,
        0, 0, 30,
    }
    indices := []i32{0, 1, 2, 0, 2, 3}
    areas := []u8{nav_recast.RC_WALKABLE_AREA, nav_recast.RC_WALKABLE_AREA}
    
    geometry, ok := recast.create_geometry_input(vertices, indices, areas)
    if !ok {
        log.error("Failed to create geometry input")
        return false
    }
    
    config := recast.create_config_from_preset(.Balanced)
    config.enable_debug_output = true
    
    // Create builder for step-by-step control
    builder := recast.create_builder(&geometry, config)
    if builder.last_error != "" {
        log.errorf("Failed to create builder: %s", builder.last_error)
        return false
    }
    defer recast.free_builder(builder)
    
    // Execute each step manually
    log.info("Rasterizing geometry...")
    if !recast.builder_rasterize(builder) {
        log.errorf("Rasterization failed: %s", builder.last_error)
        return false
    }
    
    log.info("Filtering spans...")
    if !recast.builder_filter(builder) {
        log.errorf("Filtering failed: %s", builder.last_error)
        return false
    }
    
    log.info("Building compact heightfield...")
    if !recast.builder_build_compact_heightfield(builder) {
        log.errorf("Compact heightfield failed: %s", builder.last_error)
        return false
    }
    
    // Continue with remaining steps
    steps := []proc(^recast.Navmesh_Builder) -> bool{
        recast.builder_erode_walkable_area,
        recast.builder_build_distance_field,
        recast.builder_build_regions,
        recast.builder_build_contours,
        recast.builder_build_polygon_mesh,
        recast.builder_build_detail_mesh,
    }
    
    step_names := []string{
        "Eroding walkable area",
        "Building distance field", 
        "Building regions",
        "Building contours",
        "Building polygon mesh",
        "Building detail mesh",
    }
    
    for step, i in steps {
        log.infof("%s...", step_names[i])
        if !step(builder) {
            log.errorf("Step failed: %s", builder.last_error)
            return false
        }
    }
    
    // Get final result
    pmesh, dmesh, success := recast.builder_get_result(builder)
    if !success {
        log.error("Failed to get final result")
        return false
    }
    
    defer {
        recast.rc_free_poly_mesh(pmesh)
        recast.rc_free_poly_mesh_detail(dmesh)
    }
    
    log.infof("Successfully built navigation mesh step by step: %d polygons", pmesh.npolys)
    return true
}

// Example 4: Custom area types and validation
example_custom_areas :: proc() -> bool {
    log.info("=== Example 4: Custom Areas and Validation ===")
    
    // Create geometry with different area types
    vertices := []f32{
        // Main walkable area
        0, 0, 0,
        20, 0, 0,
        20, 0, 20,
        0, 0, 20,
        // Special area (maybe a bridge or slow zone)
        25, 0, 5,
        35, 0, 5,
        35, 0, 15,
        25, 0, 15,
    }
    
    indices := []i32{
        0, 1, 2, 0, 2, 3,     // Normal walkable
        4, 5, 6, 4, 6, 7,     // Special area
    }
    
    areas := []u8{
        nav_recast.RC_WALKABLE_AREA,  // Normal
        nav_recast.RC_WALKABLE_AREA,
        10,                         // Custom area type
        10,
    }
    
    // Build with custom areas
    result := recast.build_navmesh_with_areas(vertices, indices, areas, .Balanced)
    if !result.success {
        log.errorf("Failed to build with custom areas: %s", result.error_message)
        return false
    }
    
    defer recast.free_build_result(&result)
    
    // Validate the mesh
    validation := recast.validate_navmesh(result.polygon_mesh, result.detail_mesh)
    defer recast.free_validation_report(&validation)
    
    // Print detailed validation report
    recast.print_validation_report(&validation)
    
    // Count different area types
    area_counts := map[u8]int{}
    defer delete(area_counts)
    
    for i in 0..<result.polygon_mesh.npolys {
        area := result.polygon_mesh.areas[i]
        area_counts[area] = area_counts[area] + 1
    }
    
    log.infof("Generated %d different area types:", len(area_counts))
    for area, count in area_counts {
        log.infof("  Area %d: %d polygons", area, count)
    }
    
    return true
}

// Example 5: Memory and performance estimation
example_performance_analysis :: proc() -> bool {
    log.info("=== Example 5: Performance Analysis ===")
    
    // Estimate memory and build time for different scenarios
    scenarios := []struct {
        name:       string,
        vert_count: i32,
        tri_count:  i32,
        cell_size:  f32,
    }{
        {"Small scene", 100, 200, 0.5},
        {"Medium scene", 1000, 2000, 0.3},
        {"Large scene", 10000, 20000, 0.2},
    }
    
    for scenario in scenarios {
        config := recast.create_config_from_preset(.Balanced)
        config.base.cs = scenario.cell_size
        config.base.ch = scenario.cell_size * 0.5
        config.base.bmin = {0, 0, 0}
        config.base.bmax = {100, 10, 100}  // Approximate bounds
        
        // Estimate memory usage
        bytes, breakdown := recast.estimate_memory_usage(&config, scenario.vert_count, scenario.tri_count)
        defer delete(breakdown)
        
        // Estimate build time
        estimated_time := recast.estimate_build_time(scenario.vert_count, scenario.tri_count, &config)
        
        log.infof("%s:", scenario.name)
        log.infof("  Input: %d vertices, %d triangles", scenario.vert_count, scenario.tri_count)
        log.infof("  Estimated memory: %.2f KB", f32(bytes) / 1024.0)
        log.infof("  Estimated time: %.2f ms", estimated_time)
        
        // Show memory breakdown
        log.info("  Memory breakdown:")
        for component, mem in breakdown {
            log.infof("    %s: %.2f KB", component, f32(mem) / 1024.0)
        }
    }
    
    return true
}

// Example 6: Error handling and debugging
example_error_handling :: proc() -> bool {
    log.info("=== Example 6: Error Handling ===")
    
    // Demonstrate handling various error conditions
    
    // 1. Invalid geometry
    log.info("Testing invalid geometry...")
    empty_verts := []f32{}
    empty_indices := []i32{}
    empty_areas := []u8{}
    
    _, ok := recast.create_geometry_input(empty_verts, empty_indices, empty_areas)
    if ok {
        log.error("Should have failed with empty geometry!")
        return false
    } else {
        log.info("  Correctly rejected empty geometry")
    }
    
    // 2. Invalid configuration
    log.info("Testing invalid configuration...")
    good_verts := []f32{0, 0, 0, 10, 0, 0, 10, 0, 10, 0, 0, 10}
    good_indices := []i32{0, 1, 2, 0, 2, 3}
    good_areas := []u8{nav_recast.RC_WALKABLE_AREA, nav_recast.RC_WALKABLE_AREA}
    
    geometry, _ := recast.create_geometry_input(good_verts, good_indices, good_areas)
    
    bad_config := recast.create_config_from_preset(.Balanced)
    bad_config.base.cs = -1.0  // Invalid cell size
    
    valid, err := recast.validate_enhanced_config(&bad_config)
    if valid {
        log.error("Should have failed validation!")
        return false
    } else {
        log.infof("  Correctly rejected invalid config: %s", err)
    }
    
    // 3. Build failure with invalid config
    log.info("Testing build with invalid config...")
    result := recast.build_navmesh(&geometry, bad_config)
    if result.success {
        log.error("Build should have failed!")
        return false
    } else {
        log.infof("  Correctly failed build: %s", result.error_message)
    }
    
    log.info("Error handling tests passed!")
    return true
}

// Run all examples
run_all_examples :: proc() -> bool {
    examples := []proc() -> bool{
        example_simple_navmesh,
        example_config_presets,
        example_builder_pattern,
        example_custom_areas,
        example_performance_analysis,
        example_error_handling,
    }
    
    success_count := 0
    for example, i in examples {
        log.infof("\n--- Running Example %d ---", i + 1)
        if example() {
            success_count += 1
            log.infof("Example %d: SUCCESS", i + 1)
        } else {
            log.errorf("Example %d: FAILED", i + 1)
        }
    }
    
    log.infof("\nCompleted %d/%d examples successfully", success_count, len(examples))
    return success_count == len(examples)
}