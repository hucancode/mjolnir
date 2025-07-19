package tests

import "core:testing"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Test pathfinding around a rectangular obstacle
@(test)
test_obstacle_pathfinding :: proc(t: ^testing.T) {
  log.info("=== OBSTACLE PATHFINDING TEST ===")
  
  // Create 20x20 ground with 10x2x2 obstacle in the center (matches main.odin)
  ground_vertices, ground_indices, obstacle_vertices, obstacle_indices := create_test_scene()
  
  // Combine vertices and indices
  vertices := make([][3]f32, len(ground_vertices) + len(obstacle_vertices))
  defer delete(vertices)
  copy(vertices[0:len(ground_vertices)], ground_vertices[:])
  copy(vertices[len(ground_vertices):], obstacle_vertices[:])
  
  indices := make([]u32, len(ground_indices) + len(obstacle_indices))
  defer delete(indices)
  copy(indices[0:len(ground_indices)], ground_indices[:])
  
  // Offset obstacle indices by ground vertex count
  ground_vert_count := u32(len(ground_vertices))
  for i in 0..<len(obstacle_indices) {
    offset_index := len(ground_indices) + i
    indices[offset_index] = obstacle_indices[i] + ground_vert_count
  }
  
  // Create areas - ground is walkable, obstacle is not
  areas := make([]u8, len(indices) / 3)
  defer delete(areas)
  
  ground_triangle_count := len(ground_indices) / 3
  obstacle_triangle_count := len(obstacle_indices) / 3
  
  // Mark ground triangles as walkable
  for i in 0..<ground_triangle_count {
    areas[i] = u8(nav.WALKABLE_AREA)
  }
  
  // Mark obstacle triangles as non-walkable
  for i in 0..<obstacle_triangle_count {
    areas[ground_triangle_count + i] = u8(nav.NULL_AREA)
  }
  
  log.infof("Scene: %d vertices, %d triangles (%d ground, %d obstacle)", 
           len(vertices), len(indices)/3, ground_triangle_count, obstacle_triangle_count)
  
  // Debug: Print first few vertices to check data integrity
  for i in 0..<min(4, len(vertices)) {
    log.infof("Vertex[%d]: [%.2f, %.2f, %.2f]", i, vertices[i].x, vertices[i].y, vertices[i].z)
  }
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  // Match main.odin navigation mesh configuration
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3          // Reasonable resolution
  config.agent_radius = 0.1       // Small agent expansion
  config.agent_height = 1.5       // Standard agent height
  config.agent_max_climb = 0.5    // Standard climb value
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Analyze the resulting navigation mesh
  analyze_navmesh(t, &navmesh)
  
  // Test pathfinding around the obstacle
  test_pathfinding_cases(t, &navmesh)
}

// Create the test scene geometry
create_test_scene :: proc() -> (ground_verts: [][3]f32, ground_indices: []u32, 
                               obstacle_verts: [][3]f32, obstacle_indices: []u32) {
  // Ground: 20x20 plane at y=0, centered at origin (matches main.odin)
  ground_verts = {
    {-10, 0, -10}, // 0
    {10, 0, -10},  // 1
    {10, 0, 10},   // 2
    {-10, 0, 10},  // 3
  }
  
  ground_indices = {
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }
  
  // Obstacle: 10x2x2 box centered at origin (matches main.odin)
  // Box extends from (-5, 0, -1) to (5, 2, 1)
  obstacle_verts = {
    // Bottom face (y=0)
    {-5, 0, -1}, // 0
    {5, 0, -1},  // 1
    {5, 0, 1},   // 2
    {-5, 0, 1},  // 3
    
    // Top face (y=2)
    {-5, 2, -1}, // 4
    {5, 2, -1},  // 5
    {5, 2, 1},   // 6
    {-5, 2, 1},  // 7
  }
  
  obstacle_indices = {
    // Bottom face
    0, 2, 1,  0, 3, 2,
    // Top face  
    4, 5, 6,  4, 6, 7,
    // Front face (z=4)
    0, 1, 5,  0, 5, 4,
    // Back face (z=6)
    2, 7, 6,  2, 3, 7,
    // Left face (x=2.5)
    3, 4, 7,  3, 0, 4,
    // Right face (x=7.5)
    1, 6, 5,  1, 2, 6,
  }
  
  return
}

// Analyze the navigation mesh properties
analyze_navmesh :: proc(t: ^testing.T, navmesh: ^nav.NavMesh) {
  if navmesh.max_tiles == 0 || navmesh.tiles[0].header == nil {
    testing.expect(t, false, "Should have valid navigation mesh")
    return
  }
  
  tile := &navmesh.tiles[0]
  header := tile.header
  
  log.infof("NavMesh Analysis:")
  log.infof("  Polygons: %d", header.poly_count)
  log.infof("  Vertices: %d", header.vert_count)
  
  // Count polygon connectivity
  total_links := 0
  connected_polygons := 0
  
  for i in 0..<header.poly_count {
    link_count := 0
    for link_idx := tile.polys[i].first_link; link_idx != nav.NULL_LINK; {
      if link_idx >= u32(len(tile.links)) do break
      link := &tile.links[link_idx]
      link_count += 1
      total_links += 1
      link_idx = link.next
    }
    if link_count > 0 {
      connected_polygons += 1
    }
  }
  
  log.infof("  Connected polygons: %d/%d", connected_polygons, header.poly_count)
  log.infof("  Total links: %d", total_links)
  
  testing.expect(t, total_links > 0, "NavMesh should have polygon connectivity")
  testing.expect(t, connected_polygons > 0, "Should have connected polygons")
}

// Test various pathfinding scenarios
test_pathfinding_cases :: proc(t: ^testing.T, navmesh: ^nav.NavMesh) {
  query := nav.query_init(navmesh)
  defer nav.query_deinit(&query)
  
  test_cases := []struct {
    name: string,
    start: [3]f32,
    end: [3]f32,
    should_succeed: bool,
    description: string,
  }{
    {
      name = "around_obstacle",
      start = {0, 0.1, -5},
      end = {0, 0.1, 5}, 
      should_succeed = true,
      description = "Path around obstacle from south to north",
    },
    {
      name = "left_side",
      start = {-8, 0.1, 0},
      end = {8, 0.1, 0},
      should_succeed = true,
      description = "Path around obstacle from west to east",
    },
    {
      name = "corner_to_corner",
      start = {-8, 0.1, -8},
      end = {8, 0.1, 8},
      should_succeed = true,
      description = "Diagonal path around obstacle",
    },
    {
      name = "through_obstacle",
      start = {0, 0.1, -3},
      end = {0, 0.1, 3},
      should_succeed = true,  // Should find path around, not through
      description = "Path that would go through obstacle - should route around",
    },
    {
      name = "invalid_start",
      start = {0, 1.5, 0},  // Inside obstacle (high Y)
      end = {-8, 0.1, -8},
      should_succeed = false,
      description = "Start position inside obstacle",
    },
  }
  
  log.infof("\n=== PATHFINDING TEST CASES ===")
  
  passed := 0
  total := len(test_cases)
  
  for test_case in test_cases {
    log.infof("\n--- %s ---", test_case.name)
    log.infof("Description: %s", test_case.description)
    log.infof("Start: [%.1f, %.1f, %.1f] -> End: [%.1f, %.1f, %.1f]",
              test_case.start.x, test_case.start.y, test_case.start.z,
              test_case.end.x, test_case.end.y, test_case.end.z)
    
    path, found := nav.find_path(&query, test_case.start, test_case.end)
    defer if found do delete(path)
    
    log.infof("Result: found=%v, waypoints=%d", found, len(path) if found else 0)
    
    if test_case.should_succeed && found {
      // Analyze path quality
      total_distance := f32(0)
      for i in 1..<len(path) {
        total_distance += linalg.distance(path[i-1], path[i])
      }
      
      direct_distance := linalg.distance(test_case.start, test_case.end)
      efficiency := direct_distance / total_distance if total_distance > 0 else 0
      
      log.infof("Path analysis: distance=%.2f, direct=%.2f, efficiency=%.1f%%",
                total_distance, direct_distance, efficiency * 100)
      
      // Verify path doesn't go through obstacle
      obstacle_violation := false
      for point in path {
        // Check if point is inside obstacle bounds (-5 <= x <= 5, -1 <= z <= 1, 0 <= y <= 2)
        if point.x >= -5 && point.x <= 5 && point.z >= -1 && point.z <= 1 && point.y > 0.2 {
          obstacle_violation = true
          log.errorf("Path goes through obstacle at [%.2f, %.2f, %.2f]", point.x, point.y, point.z)
          break
        }
      }
      
      if !obstacle_violation && efficiency > 0.3 {  // Reasonable efficiency for obstacle avoidance
        log.infof("✅ PASSED: %s", test_case.name)
        passed += 1
      } else {
        log.errorf("❌ FAILED: %s - %s", test_case.name, 
                   obstacle_violation ? "path through obstacle" : "poor efficiency")
        testing.expect(t, false, test_case.name)
      }
      
    } else if !test_case.should_succeed && !found {
      log.infof("✅ PASSED: %s (correctly failed)", test_case.name)
      passed += 1
      
    } else {
      log.errorf("❌ FAILED: %s - expected success=%v, got found=%v", 
                 test_case.name, test_case.should_succeed, found)
      testing.expect(t, false, test_case.name)
    }
  }
  
  log.infof("\n=== PATHFINDING SUMMARY ===")
  log.infof("Passed: %d/%d tests", passed, total)
  
  success_rate := f32(passed) / f32(total)
  testing.expect(t, success_rate >= 0.8, "Should pass at least 80% of pathfinding tests")
}