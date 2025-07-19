package tests

import "core:testing"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// STEP 1: Test navigation mesh creation and basic structure
@(test)
test_navmesh_creation :: proc(t: ^testing.T) {
  log.info("=== STEP 1: Navigation Mesh Creation ===")
  
  // Simple 2-triangle ground
  vertices := [][3]f32{
    {-5, 0, -5},  // 0
    { 5, 0, -5},  // 1
    { 5, 0,  5},  // 2
    {-5, 0,  5},  // 3
  }
  
  indices := []u32{
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  
  navmesh, success := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  testing.expect(t, success, "Navigation mesh should build successfully")
  
  if success {
    log.info("✓ Navigation mesh created successfully")
    
    // Check basic mesh properties
    testing.expect(t, navmesh.max_tiles > 0, "NavMesh should have tiles")
    
    // Log mesh statistics for verification
    if navmesh.max_tiles > 0 && navmesh.tiles[0].header != nil {
      header := navmesh.tiles[0].header
      log.infof("  Polygons: %d", header.poly_count)
      log.infof("  Vertices: %d", header.vert_count)
      log.infof("  Links: %d", header.max_link_count)
    }
  }
}

// STEP 2: Test polygon finding (nearest polygon to a position)
@(test)
test_polygon_finding :: proc(t: ^testing.T) {
  log.info("=== STEP 2: Polygon Finding ===")
  
  navmesh, ok := create_simple_navmesh()
  if !ok {
    testing.expect(t, false, "Failed to create test navmesh")
    return
  }
  defer nav.destroy(&navmesh)
  
  query := nav.query_init(&navmesh)
  defer nav.query_deinit(&query)
  
  // Test positions and expected results
  test_positions := [][3]f32{
    {0, 0.1, 0},     // Center - should find polygon
    {-2, 0.1, -2},   // Corner - should find polygon  
    {0, 0.1, 0},     // Duplicate position
    {100, 0.1, 100}, // Far outside - should fail
  }
  
  for pos, i in test_positions {
    poly_ref := nav.find_nearest_poly_ref(&navmesh, pos, {2, 4, 2})
    
    log.infof("Position [%.1f, %.1f, %.1f] -> polygon 0x%x", pos.x, pos.y, pos.z, poly_ref)
    
    if i < 3 { // First 3 should succeed
      testing.expect(t, poly_ref != 0, "Should find polygon for valid position")
      if poly_ref != 0 {
        center := nav.get_poly_center(&navmesh, poly_ref)
        log.infof("  Polygon center: [%.2f, %.2f, %.2f]", center.x, center.y, center.z)
      }
    } else { // Last one should fail
      testing.expect(t, poly_ref == 0, "Should not find polygon for invalid position")
    }
  }
}

// STEP 3: Test polygon flags and filtering
@(test)
test_polygon_flags :: proc(t: ^testing.T) {
  log.info("=== STEP 3: Polygon Flags and Filtering ===")
  
  navmesh, ok := create_simple_navmesh()
  if !ok {
    testing.expect(t, false, "Failed to create test navmesh")
    return
  }
  defer nav.destroy(&navmesh)
  
  // Check that polygons have correct flags
  if navmesh.max_tiles > 0 && navmesh.tiles[0].header != nil {
    tile := &navmesh.tiles[0]
    header := tile.header
    
    log.infof("Checking %d polygons for flags:", header.poly_count)
    
    walkable_count := 0
    for i in 0..<header.poly_count {
      poly := &tile.polys[i]
      area := nav.get_poly_area(poly)
      
      log.infof("  Polygon %d: flags=0x%x, area=%d", i, poly.flags, area)
      
      if poly.flags & nav.POLYFLAGS_WALK != 0 {
        walkable_count += 1
      }
    }
    
    testing.expect(t, walkable_count > 0, "Should have at least one walkable polygon")
    log.infof("✓ Found %d walkable polygons out of %d total", walkable_count, header.poly_count)
  }
}

// STEP 4: Test polygon connectivity (links between polygons)
@(test)
test_polygon_connectivity :: proc(t: ^testing.T) {
  log.info("=== STEP 4: Polygon Connectivity ===")
  
  navmesh, ok := create_simple_navmesh()
  if !ok {
    testing.expect(t, false, "Failed to create test navmesh")
    return
  }
  defer nav.destroy(&navmesh)
  
  if navmesh.max_tiles > 0 && navmesh.tiles[0].header != nil {
    tile := &navmesh.tiles[0]
    header := tile.header
    
    log.infof("Checking connectivity for %d polygons:", header.poly_count)
    
    total_links := 0
    connected_polys := 0
    
    for i in 0..<header.poly_count {
      poly := &tile.polys[i]
      poly_ref := nav.encode_poly_id(tile.salt, 0, u32(i))
      
      link_count := 0
      for link_idx := poly.first_link; link_idx != nav.NULL_LINK; {
        if link_idx >= u32(len(tile.links)) do break
        link := &tile.links[link_idx]
        link_count += 1
        total_links += 1
        link_idx = link.next
      }
      
      log.infof("  Polygon 0x%x: %d links", poly_ref, link_count)
      
      if link_count > 0 {
        connected_polys += 1
      }
    }
    
    log.infof("✓ Total links: %d, Connected polygons: %d/%d", 
              total_links, connected_polys, header.poly_count)
    
    testing.expect(t, total_links > 0, "Should have polygon links")
    testing.expect(t, connected_polys > 0, "Should have connected polygons")
  }
}

// STEP 5: Test A* search (polygon path finding)
@(test)
test_astar_polygon_search :: proc(t: ^testing.T) {
  log.info("=== STEP 5: A* Polygon Search ===")
  
  navmesh, ok := create_simple_navmesh()
  if !ok {
    testing.expect(t, false, "Failed to create test navmesh")
    return
  }
  defer nav.destroy(&navmesh)
  
  query := nav.query_init(&navmesh)
  defer nav.query_deinit(&query)
  
  // Test simple polygon path
  start_pos := [3]f32{-2, 0.1, 0}
  end_pos := [3]f32{2, 0.1, 0}
  
  log.infof("Searching polygon path from [%.1f, %.1f, %.1f] to [%.1f, %.1f, %.1f]", 
            start_pos.x, start_pos.y, start_pos.z, end_pos.x, end_pos.y, end_pos.z)
  
  // Find start and end polygons
  start_ref := nav.find_nearest_poly_ref(&navmesh, start_pos, {2, 4, 2})
  end_ref := nav.find_nearest_poly_ref(&navmesh, end_pos, {2, 4, 2})
  
  log.infof("Start polygon: 0x%x, End polygon: 0x%x", start_ref, end_ref)
  
  testing.expect(t, start_ref != 0, "Should find start polygon")
  testing.expect(t, end_ref != 0, "Should find end polygon")
  
  if start_ref != 0 && end_ref != 0 {
    // Run A* search
    poly_path := nav.find_polygon_path(&query, start_ref, end_ref, start_pos, end_pos)
    defer delete(poly_path)
    
    log.infof("Polygon path found: %d polygons", len(poly_path))
    
    for poly_ref, i in poly_path {
      center := nav.get_poly_center(&navmesh, poly_ref)
      log.infof("  %d: 0x%x at [%.2f, %.2f, %.2f]", i, poly_ref, center.x, center.y, center.z)
    }
    
    testing.expect(t, len(poly_path) > 0, "Should find polygon path")
    if len(poly_path) > 0 {
      testing.expect(t, poly_path[0] == start_ref, "Path should start with start polygon")
      testing.expect(t, poly_path[len(poly_path)-1] == end_ref, "Path should end with end polygon")
    }
  }
}

// STEP 6: Test string pulling (final path generation)
@(test)
test_string_pulling :: proc(t: ^testing.T) {
  log.info("=== STEP 6: String Pulling ===")
  
  navmesh, ok := create_simple_navmesh()
  if !ok {
    testing.expect(t, false, "Failed to create test navmesh")
    return
  }
  defer nav.destroy(&navmesh)
  
  query := nav.query_init(&navmesh)
  defer nav.query_deinit(&query)
  
  start_pos := [3]f32{-2, 0.1, 0}
  end_pos := [3]f32{2, 0.1, 0}
  
  log.infof("Testing string pulling from [%.1f, %.1f, %.1f] to [%.1f, %.1f, %.1f]", 
            start_pos.x, start_pos.y, start_pos.z, end_pos.x, end_pos.y, end_pos.z)
  
  // First get polygon path
  start_ref := nav.find_nearest_poly_ref(&navmesh, start_pos, {2, 4, 2})
  end_ref := nav.find_nearest_poly_ref(&navmesh, end_pos, {2, 4, 2})
  
  if start_ref != 0 && end_ref != 0 {
    poly_path := nav.find_polygon_path(&query, start_ref, end_ref, start_pos, end_pos)
    defer delete(poly_path)
    
    if len(poly_path) > 0 {
      // Test string pulling
      final_path := nav.string_pull_path(&navmesh, poly_path, start_pos, end_pos)
      defer delete(final_path)
      
      log.infof("String pulling result: %d waypoints", len(final_path))
      
      for point, i in final_path {
        log.infof("  %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
      }
      
      testing.expect(t, len(final_path) >= 2, "Should have at least start and end points")
      
      if len(final_path) >= 2 {
        start_dist := linalg.distance(final_path[0], start_pos)
        end_dist := linalg.distance(final_path[len(final_path)-1], end_pos)
        
        log.infof("Start distance: %.3f, End distance: %.3f", start_dist, end_dist)
        
        testing.expect(t, start_dist < 0.5, "Path should start near start position")
        testing.expect(t, end_dist < 0.5, "Path should end near end position")
      }
    }
  }
}

// STEP 7: Test complete pathfinding pipeline
@(test)
test_complete_pathfinding :: proc(t: ^testing.T) {
  log.info("=== STEP 7: Complete Pathfinding Pipeline ===")
  
  navmesh, ok := create_simple_navmesh()
  if !ok {
    testing.expect(t, false, "Failed to create test navmesh")
    return
  }
  defer nav.destroy(&navmesh)
  
  query := nav.query_init(&navmesh)
  defer nav.query_deinit(&query)
  
  // Test the complete pipeline
  start_pos := [3]f32{-3, 0.1, -3}
  end_pos := [3]f32{3, 0.1, 3}
  
  log.infof("Complete pathfinding test from [%.1f, %.1f, %.1f] to [%.1f, %.1f, %.1f]", 
            start_pos.x, start_pos.y, start_pos.z, end_pos.x, end_pos.y, end_pos.z)
  
  path, found := nav.find_path(&query, start_pos, end_pos)
  defer if found do delete(path)
  
  log.infof("Path found: %v", found)
  
  if found {
    log.infof("Final path: %d waypoints", len(path))
    
    total_distance := f32(0)
    for i in 1..<len(path) {
      segment_dist := linalg.distance(path[i-1], path[i])
      total_distance += segment_dist
      log.infof("  %d: [%.2f, %.2f, %.2f] (dist: %.2f)", 
                i-1, path[i-1].x, path[i-1].y, path[i-1].z, segment_dist)
    }
    
    log.infof("  %d: [%.2f, %.2f, %.2f]", 
              len(path)-1, path[len(path)-1].x, path[len(path)-1].y, path[len(path)-1].z)
    log.infof("Total distance: %.2f", total_distance)
    
    testing.expect(t, len(path) >= 2, "Should have at least 2 waypoints")
    testing.expect(t, total_distance > 0, "Path should have positive distance")
    
    // Check that path is reasonable (not too long)
    direct_distance := linalg.distance(start_pos, end_pos)
    efficiency := direct_distance / total_distance
    log.infof("Path efficiency: %.2f%% (direct: %.2f, actual: %.2f)", 
              efficiency * 100, direct_distance, total_distance)
    
    testing.expect(t, efficiency > 0.5, "Path efficiency should be at least 50%")
  }
  
  testing.expect(t, found, "Should find a path for this simple case")
}

// Helper function to create a simple test navigation mesh
create_simple_navmesh :: proc() -> (nav.NavMesh, bool) {
  vertices := [][3]f32{
    {-5, 0, -5},  // 0
    { 5, 0, -5},  // 1  
    { 5, 0,  5},  // 2
    {-5, 0,  5},  // 3
  }
  
  indices := []u32{
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  
  return mjolnir.build_navmesh(input, config)
}