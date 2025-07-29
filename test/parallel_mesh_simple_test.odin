package tests

import "core:testing"
import "core:log"
import "core:time"
import nav_recast "../mjolnir/navigation/recast"

// Test that parallel mesh config can be created
@(test)
test_parallel_mesh_config :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test default config
    default_config := nav_recast.PARALLEL_MESH_DEFAULT_CONFIG
    testing.expect(t, default_config.max_workers == 0, "Default config should auto-detect workers")
    testing.expect(t, default_config.chunk_size > 0, "Default chunk size should be positive")
    testing.expect(t, default_config.enable_vertex_weld, "Default should enable vertex welding")
    testing.expect(t, default_config.weld_tolerance > 0, "Default weld tolerance should be positive")
    
    // Test custom config
    custom_config := nav_recast.Parallel_Mesh_Config{
        max_workers = 4,
        chunk_size = 16,
        enable_vertex_weld = false,
        weld_tolerance = 0.0,
    }
    testing.expect(t, custom_config.max_workers == 4, "Custom config should respect max_workers")
    testing.expect(t, custom_config.chunk_size == 16, "Custom config should respect chunk_size")
    testing.expect(t, !custom_config.enable_vertex_weld, "Custom config should respect vertex_weld")
    
    log.info("Parallel mesh configuration test completed successfully")
}

// Test that Enhanced_Config includes parallel mesh options
@(test)
test_enhanced_config_parallel :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test Fast preset
    fast_config := nav_recast.create_config_from_preset(.Fast)
    testing.expect(t, fast_config.enable_parallel_mesh, "Fast preset should enable parallel mesh")
    testing.expect(t, fast_config.parallel_mesh_config.chunk_size > 0, "Fast preset should have valid chunk size")
    
    // Test Balanced preset
    balanced_config := nav_recast.create_config_from_preset(.Balanced)
    testing.expect(t, balanced_config.enable_parallel_mesh, "Balanced preset should enable parallel mesh")
    testing.expect(t, balanced_config.parallel_mesh_config.enable_vertex_weld, "Balanced should enable vertex welding")
    
    // Test High Quality preset
    quality_config := nav_recast.create_config_from_preset(.High_Quality)
    testing.expect(t, quality_config.enable_parallel_mesh, "High Quality preset should enable parallel mesh")
    testing.expect(t, quality_config.parallel_mesh_config.weld_tolerance > 0, "Quality should have weld tolerance")
    
    log.info("Enhanced config parallel options test completed successfully")
}

// Test parallel mesh API exists and can be called
@(test)
test_parallel_mesh_api_exists :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create minimal test data
    cset := nav_recast.rc_alloc_contour_set()
    defer nav_recast.rc_free_contour_set(cset)
    
    pmesh := nav_recast.rc_alloc_poly_mesh()
    defer nav_recast.rc_free_poly_mesh(pmesh)
    
    config := nav_recast.PARALLEL_MESH_DEFAULT_CONFIG
    
    // Call should exist and handle empty input gracefully
    result := nav_recast.rc_build_poly_mesh_parallel(cset, 6, pmesh, config)
    testing.expect(t, !result, "Should return false for empty contour set")
    
    log.info("Parallel mesh API existence test completed successfully")
}