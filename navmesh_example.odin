package main

import "core:log"
import "mjolnir/navigation"
import "mjolnir/navigation/recast"

// Minimal navigation mesh example demonstrating Recast API
navmesh_simple_main :: proc() {
    log.info("=== Navigation Mesh Example ===")
    log.info("Demonstrating Recast API: ground plane with obstacle")
    
    // Initialize navigation memory
    navigation.nav_memory_init()
    defer navigation.nav_memory_shutdown()
    
    // Create test geometry - ground plane (20x20) with box obstacle (2x3x2) in center
    vertices := []f32{
        // Ground plane
        -10, 0, -10,  10, 0, -10,  10, 0, 10,  -10, 0, 10,
        // Obstacle bottom
        -1, 0, -1,  1, 0, -1,  1, 0, 1,  -1, 0, 1,
        // Obstacle top
        -1, 3, -1,  1, 3, -1,  1, 3, 1,  -1, 3, 1,
    }
    
    indices := []i32{
        // Ground triangles
        0, 1, 2,  0, 2, 3,
        // Obstacle bottom
        4, 6, 5,  4, 7, 6,
        // Obstacle top
        8, 9, 10,  8, 10, 11,
    }
    
    areas := []u8{
        recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA,  // Ground
        recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA,  // Obstacle bottom
        recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA,  // Obstacle top
    }
    
    // Configure Recast
    config := recast.Config{
        cs = 0.3,                        // Cell size
        ch = 0.2,                        // Cell height
        walkable_slope_angle = 45,       // Max slope
        walkable_height = 10,            // Min ceiling height
        walkable_climb = 4,              // Max ledge height
        walkable_radius = 2,             // Agent radius
        max_edge_len = 12,               // Max edge length
        max_simplification_error = 1.3,  // Simplification error
        min_region_area = 8,             // Min region area
        merge_region_area = 20,          // Merge region area
        max_verts_per_poly = 6,          // Max verts per polygon
        detail_sample_dist = 6,          // Detail sample distance
        detail_sample_max_error = 1,     // Detail sample error
    }
    
    // Build navigation mesh
    log.info("\nBuilding navigation mesh...")
    log.infof("Input: %d vertices, %d triangles", len(vertices)/3, len(indices)/3)
    
    pmesh, dmesh, ok := recast.rc_build_navmesh(vertices, indices, areas, config)
    if !ok {
        log.error("Failed to build navigation mesh")
        return
    }
    defer {
        if pmesh != nil do recast.rc_free_poly_mesh(pmesh)
        if dmesh != nil do recast.rc_free_poly_mesh_detail(dmesh)
    }
    
    // Report results
    log.info("\n✓ Navigation mesh built successfully!")
    log.infof("Results:")
    log.infof("  - Polygons: %d", pmesh.npolys)
    log.infof("  - Vertices: %d", len(pmesh.verts))
    log.infof("  - Bounds: min(%.1f, %.1f, %.1f) max(%.1f, %.1f, %.1f)", 
              pmesh.bmin[0], pmesh.bmin[1], pmesh.bmin[2],
              pmesh.bmax[0], pmesh.bmax[1], pmesh.bmax[2])
    
    // Show polygon details
    log.info("\nPolygon details:")
    for i in 0..<min(5, pmesh.npolys) {
        // Polygon data is stored as array of vertex indices
        poly_base := i * pmesh.nvp * 2
        nverts := 0
        for j in 0..<pmesh.nvp {
            if pmesh.polys[poly_base + j] == recast.RC_MESH_NULL_IDX {
                break
            }
            nverts += 1
        }
        area := pmesh.areas[i] if int(i) < len(pmesh.areas) else 0
        log.infof("  Polygon %d: %d vertices, area=%d", i, nverts, area)
    }
    
    log.info("\n=== Example Complete ===")
}