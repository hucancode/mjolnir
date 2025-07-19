package tests

import "../mjolnir"
import "../mjolnir/navigation"
import "core:log"
import "core:testing"

// Test string pulling with a specific corner case
@(test)
test_string_pulling_corner :: proc(t: ^testing.T) {
  // Create a maze-like structure that forces going around corners
  // We'll create a U-shaped path
  vertices := [][3]f32{
    // Left corridor
    {0, 0, 0}, {2, 0, 0}, {2, 0, 6}, {0, 0, 6},
    // Bottom connector
    {2, 0, 0}, {8, 0, 0}, {8, 0, 2}, {2, 0, 2},
    // Right corridor
    {6, 0, 2}, {8, 0, 2}, {8, 0, 6}, {6, 0, 6},
  }
  
  indices := []u32{
    // Left corridor
    0, 1, 2, 0, 2, 3,
    // Bottom connector
    4, 5, 6, 4, 6, 7,
    // Right corridor
    8, 9, 10, 8, 10, 11,
  }
  
  areas := []u8{
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
  }
  
  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3  // Fine resolution to get multiple polygons
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "U-shaped navigation mesh should build")
  defer navigation.destroy(&navmesh)
  
  query := navigation.query_init(&navmesh)
  defer navigation.query_deinit(&query)
  
  // Path from top-left to top-right, forcing navigation through the U
  start := [3]f32{1, 0, 5}   // Top of left corridor
  end := [3]f32{7, 0, 5}     // Top of right corridor
  
  path, path_found := navigation.find_path(&query, start, end)
  testing.expect(t, path_found, "Should find path through U-shape")
  
  if path_found {
    defer delete(path)
    testing.expect(t, len(path) >= 3, "Path should have at least 3 waypoints (start, corner(s), end)")
    
    log.infof("String pulled path through U-shape has %d points:", len(path))
    for point, i in path {
      log.infof("  Point %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
    }
    
    // Verify path doesn't cut through the obstacle (middle area)
    for point, i in path {
      in_obstacle := point.x > 2 && point.x < 6 && point.z > 2 && point.z < 6
      testing.expectf(t, !in_obstacle, 
        "Path point %d at [%.2f, %.2f, %.2f] should not be in obstacle area", 
        i, point.x, point.y, point.z)
    }
    
    // Check that we have corners at expected locations
    // We expect corners near (2, 0, 2) and (6, 0, 2) for the U-shape turns
    found_left_corner := false
    found_right_corner := false
    for point in path {
      // Check for left corner (around x=2, z=0-2)
      if point.x >= 1.5 && point.x <= 2.5 && point.z >= 0 && point.z <= 2.5 {
        found_left_corner = true
      }
      // Check for right corner (around x=6, z=0-2)
      if point.x >= 5.5 && point.x <= 6.5 && point.z >= 0 && point.z <= 2.5 {
        found_right_corner = true
      }
    }
    
    testing.expect(t, found_left_corner, "Path should have a corner near the left turn")
    testing.expect(t, found_right_corner, "Path should have a corner near the right turn")
  }
}

// Test string pulling with multiple consecutive corners
@(test)
test_string_pulling_zigzag :: proc(t: ^testing.T) {
  // Create a zigzag corridor
  vertices := [][3]f32{
    // First segment (horizontal)
    {0, 0, 0}, {3, 0, 0}, {3, 0, 2}, {0, 0, 2},
    // Second segment (vertical)
    {2, 0, 2}, {3, 0, 2}, {3, 0, 5}, {2, 0, 5},
    // Third segment (horizontal)
    {3, 0, 4}, {6, 0, 4}, {6, 0, 5}, {3, 0, 5},
  }
  
  indices := []u32{
    0, 1, 2, 0, 2, 3,   // First segment
    4, 5, 6, 4, 6, 7,   // Second segment
    8, 9, 10, 8, 10, 11, // Third segment
  }
  
  areas := []u8{
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
  }
  
  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Zigzag navigation mesh should build")
  defer navigation.destroy(&navmesh)
  
  query := navigation.query_init(&navmesh)
  defer navigation.query_deinit(&query)
  
  // Path from start to end of zigzag
  start := [3]f32{1.5, 0, 1}   // Middle of first segment
  end := [3]f32{4.5, 0, 4.5}   // Middle of third segment
  
  path, path_found := navigation.find_path(&query, start, end)
  testing.expect(t, path_found, "Should find path through zigzag")
  
  if path_found {
    defer delete(path)
    testing.expect(t, len(path) >= 3, "Path should have corners")
    
    log.infof("String pulled path through zigzag has %d points:", len(path))
    for point, i in path {
      log.infof("  Point %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
    }
    
    // The path should have turns at the corners
    // We expect the string pulling to create an efficient path with corners
    // at the turning points of the zigzag
  }
}