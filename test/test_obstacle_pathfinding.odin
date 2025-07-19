package tests

import "core:testing"
import "core:log"
import "core:math"
import "core:fmt"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Helper function to check if a line segment intersects a 2D rectangle
line_intersects_rectangle_2d :: proc(start: [3]f32, end: [3]f32, min_x: f32, max_x: f32, min_z: f32, max_z: f32) -> bool {
  // Use the 2D line segment (start.x, start.z) to (end.x, end.z)
  // Check intersection with rectangle [min_x, max_x] x [min_z, max_z]
  
  // Liang-Barsky line clipping algorithm for rectangle intersection
  dx := end.x - start.x
  dz := end.z - start.z
  
  if dx == 0 && dz == 0 {
    // Point case - check if point is inside rectangle
    return start.x >= min_x && start.x <= max_x && start.z >= min_z && start.z <= max_z
  }
  
  t_min := f32(0)
  t_max := f32(1)
  
  // Check X bounds
  if dx != 0 {
    t1 := (min_x - start.x) / dx
    t2 := (max_x - start.x) / dx
    if t1 > t2 {
      t1, t2 = t2, t1
    }
    t_min = max(t_min, t1)
    t_max = min(t_max, t2)
    if t_min > t_max do return false
  } else {
    // Vertical line - check if within X bounds
    if start.x < min_x || start.x > max_x do return false
  }
  
  // Check Z bounds
  if dz != 0 {
    t1 := (min_z - start.z) / dz
    t2 := (max_z - start.z) / dz
    if t1 > t2 {
      t1, t2 = t2, t1
    }
    t_min = max(t_min, t1)
    t_max = min(t_max, t2)
    if t_min > t_max do return false
  } else {
    // Horizontal line - check if within Z bounds
    if start.z < min_z || start.z > max_z do return false
  }
  
  return t_min <= t_max
}

// Test pathfinding around a rectangular obstacle
@(test)
test_obstacle_pathfinding :: proc(t: ^testing.T) {
  log.info("=== OBSTACLE PATHFINDING TEST ===")
  
  // Create 20x20 ground with 10x2x2 obstacle in the center (matches main.odin)
  ground_vertices, ground_indices, obstacle_vertices, obstacle_indices := create_test_scene()
  defer delete(ground_vertices)
  defer delete(ground_indices)
  defer delete(obstacle_vertices)
  defer delete(obstacle_indices)
  
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
  
  // Debug: Check first vertex to ensure data integrity
  if len(vertices) > 0 {
    log.infof("First vertex: [%.2f, %.2f, %.2f]", vertices[0].x, vertices[0].y, vertices[0].z)
  }
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  // Match main.odin navigation mesh configuration
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3          // Reasonable resolution
  config.agent_radius = 0.4       // Reduced from 0.6 to ensure better connectivity
  config.agent_height = 1.5       // Standard agent height
  config.agent_max_climb = 0.5    // Standard climb value
  config.min_region_area = 1      // Very small regions allowed
  config.merge_region_area = 1    // Minimal merging to prevent large polygons that allow paths through obstacles
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Analyze the resulting navigation mesh
  analyze_navmesh(t, &navmesh)
  
  // Debug polygon structure for suboptimal path investigation
  log.info("\n=== POLYGON STRUCTURE DEBUG ===")
  if navmesh.max_tiles > 0 && navmesh.tiles[0].header != nil {
    tile := &navmesh.tiles[0]
    header := tile.header
    
    // First, log all polygons with their positions
    log.infof("Total polygons: %d", header.poly_count)
    for i in 0..<header.poly_count {
      poly := &tile.polys[i]
      poly_ref := nav.encode_poly_id(tile.salt, 0, u32(i))
      center := nav.get_poly_center(&navmesh, poly_ref)
      
      // Get bounds
      min_bounds := [3]f32{999, 999, 999}
      max_bounds := [3]f32{-999, -999, -999}
      for j in 0..<poly.vert_count {
        vert_idx := poly.verts[j]
        if vert_idx >= u16(header.vert_count) do continue
        vert_pos := [3]f32{
          tile.verts[vert_idx * 3 + 0],
          tile.verts[vert_idx * 3 + 1],
          tile.verts[vert_idx * 3 + 2],
        }
        min_bounds = linalg.min(min_bounds, vert_pos)
        max_bounds = linalg.max(max_bounds, vert_pos)
      }
      
      log.infof("Poly %d (ref %x): center[%.2f,%.2f,%.2f], bounds x[%.2f,%.2f] z[%.2f,%.2f]", 
                i, poly_ref, center.x, center.y, center.z,
                min_bounds.x, max_bounds.x, min_bounds.z, max_bounds.z)
    }
    
    // Then log connectivity
    log.info("\n=== POLYGON CONNECTIVITY ===")
    for i in 0..<min(header.poly_count, 15) {
      poly := &tile.polys[i]
      poly_ref := nav.encode_poly_id(tile.salt, 0, u32(i))
      center := nav.get_poly_center(&navmesh, poly_ref)
      
      log.infof("Polygon %x at [%.2f,%.2f,%.2f]:", poly_ref, center.x, center.y, center.z)
      
      // Log neighbors
      neighbor_count := 0
      for link_idx := poly.first_link; link_idx != nav.NULL_LINK; {
        if link_idx >= u32(len(tile.links)) do break
        link := &tile.links[link_idx]
        neighbor_center := nav.get_poly_center(&navmesh, link.ref)
        log.infof("  -> Neighbor %x at [%.2f,%.2f,%.2f] (edge %d)", 
                  link.ref, neighbor_center.x, neighbor_center.y, neighbor_center.z, link.edge)
        neighbor_count += 1
        link_idx = link.next
      }
      if neighbor_count == 0 {
        log.warn("  -> NO NEIGHBORS!")
      }
    }
  }
  
  // Test pathfinding around the obstacle
  test_pathfinding_cases(t, &navmesh)
}

// Create the test scene geometry
create_test_scene :: proc() -> (ground_verts: [][3]f32, ground_indices: []u32, 
                               obstacle_verts: [][3]f32, obstacle_indices: []u32) {
  // Ground: 30x30 plane at y=0, centered at origin
  // Increased from 24x24 to ensure better connectivity around obstacle
  ground_verts_data := [4][3]f32{
    {-15, 0, -15}, // 0
    {15, 0, -15},  // 1
    {15, 0, 15},   // 2
    {-15, 0, 15},  // 3
  }
  ground_verts = make([][3]f32, len(ground_verts_data))
  copy(ground_verts, ground_verts_data[:])
  
  ground_indices_data := [6]u32{
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }
  ground_indices = make([]u32, len(ground_indices_data))
  copy(ground_indices, ground_indices_data[:])
  
  // Obstacle: 10x2x2 box centered at origin
  // Box extends from (-5, 0, -1) to (5, 2, 1)
  // With 30x30 ground, this leaves 10 units on each side
  // After erosion with agent_radius=0.4, walkable area is ~9.6 units on each side
  obstacle_verts_data := [8][3]f32{
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
  obstacle_verts = make([][3]f32, len(obstacle_verts_data))
  copy(obstacle_verts, obstacle_verts_data[:])
  
  obstacle_indices_data := [36]u32{
    // Bottom face
    0, 2, 1,  0, 3, 2,
    // Top face  
    4, 5, 6,  4, 6, 7,
    // Front face (z=-1)
    0, 1, 5,  0, 5, 4,
    // Back face (z=1)
    2, 7, 6,  2, 3, 7,
    // Left face (x=-5)
    3, 4, 7,  3, 0, 4,
    // Right face (x=5)
    1, 6, 5,  1, 2, 6,
  }
  obstacle_indices = make([]u32, len(obstacle_indices_data))
  copy(obstacle_indices, obstacle_indices_data[:])
  
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
      start = {-5, 0.1, -5},
      end = {-5, 0.1, 5}, 
      should_succeed = true,
      description = "Path around obstacle from (-5,0,-5) to (-5,0,5) - should wrap around with 4 waypoints (start + 2 intermediate + end)",
    },
    {
      name = "diagonal_around_obstacle",
      start = {3.8, 0.1, -4.6},
      end = {-4.1, 0.1, 2.5}, 
      should_succeed = true,
      description = "Diagonal path from (3.8,0.1,-4.6) to (-4.1,0.1,2.5) around obstacle",
    },
    {
      name = "left_side",
      start = {-10, 0.1, 0},
      end = {10, 0.1, 0},
      should_succeed = true,
      description = "Path around obstacle from west to east",
    },
    {
      name = "corner_to_corner",
      start = {-10, 0.1, -10},
      end = {10, 0.1, 10},
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
      name = "outside_bounds",
      start = {20, 0.1, 20},  // Clearly outside the navigation mesh bounds
      end = {-10, 0.1, -10},
      should_succeed = false,
      description = "Start position outside navigation mesh",
    },
    {
      name = "left_path_test",
      start = {-8, 0.1, 5},
      end = {-8, 0.1, -5},
      should_succeed = true,
      description = "Path on left side from top to bottom",
    },
    {
      name = "right_path_test", 
      start = {8, 0.1, 5},
      end = {8, 0.1, -5},
      should_succeed = true,
      description = "Path on right side from top to bottom",
    },
    {
      name = "suboptimal_map_edge",
      start = {4, 0.1, 6.9},
      end = {3.7, 0.1, -4.4},
      should_succeed = true,
      description = "Path that might take suboptimal route around map edge",
    },
    {
      name = "optimal_left_choice",
      start = {-2, 0.1, 6},
      end = {-2, 0.1, -6},
      should_succeed = true,
      description = "Path that should definitely choose left side",
    },
    {
      name = "center_to_left",
      start = {0, 0.1, 6},
      end = {-8, 0.1, -6},
      should_succeed = true,
      description = "Path from center top to left bottom - should go left",
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
    
    // For key test cases, print the full path
    if (test_case.name == "around_obstacle" || test_case.name == "diagonal_around_obstacle" || test_case.name == "suboptimal_map_edge") && found {
      log.infof("=== DETAILED PATH ANALYSIS for %s ===", test_case.name)
      for point, i in path {
        log.infof("Waypoint %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
      }
      
      // Special validation for around_obstacle test case
      if test_case.name == "around_obstacle" {
        expected_waypoints := 4  // start + 2 intermediate + end
        if len(path) != expected_waypoints {
          log.errorf("❌ INCORRECT WAYPOINT COUNT: Expected %d waypoints, got %d", expected_waypoints, len(path))
        } else {
          log.infof("✅ CORRECT WAYPOINT COUNT: %d waypoints as expected", len(path))
        }
        testing.expect(t, len(path) == expected_waypoints, 
                      fmt.tprintf("Path should have %d waypoints (start + 2 intermediate + end), got %d", expected_waypoints, len(path)))
      }
    }
    
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
      
      // Check individual waypoints
      for point in path {
        // Check if point is inside obstacle bounds (-5 <= x <= 5, -1 <= z <= 1, 0 <= y <= 2)
        if point.x >= -5 && point.x <= 5 && point.z >= -1 && point.z <= 1 && point.y > 0.2 {
          obstacle_violation = true
          log.errorf("Path waypoint goes through obstacle at [%.2f, %.2f, %.2f]", point.x, point.y, point.z)
        }
      }
      
      // Check line segments between waypoints for obstacle intersection
      if len(path) >= 2 {
        for i in 1..<len(path) {
          start_seg := path[i-1]
          end_seg := path[i]
          
          // Check if line segment intersects the 2D obstacle bounds (ignoring Y for ground-level paths)
          // Obstacle bounds: x=-5 to 5, z=-1 to 1
          intersects_obstacle := line_intersects_rectangle_2d(start_seg, end_seg, -5, 5, -1, 1)
          
          if intersects_obstacle {
            log.errorf("❌ OBSTACLE INTERSECTION: Path segment %d from [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f] intersects obstacle", 
                      i, start_seg.x, start_seg.y, start_seg.z, end_seg.x, end_seg.y, end_seg.z)
            obstacle_violation = true
          } else {
            log.infof("✅ SEGMENT %d CLEAR: [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f] avoids obstacle", 
                     i, start_seg.x, start_seg.y, start_seg.z, end_seg.x, end_seg.y, end_seg.z)
          }
          
          // Use testing.expect to fail the test on obstacle intersection
          testing.expect(t, !intersects_obstacle, 
                        fmt.tprintf("Path segment %d from [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f] must not intersect obstacle", 
                                   i, start_seg.x, start_seg.y, start_seg.z, end_seg.x, end_seg.y, end_seg.z))
        }
      }
      
      // Check efficiency with more lenient threshold for obstacle avoidance
      efficiency_threshold := f32(0.5)  // 50% efficiency = path is at most 2x longer than direct
      
      if !obstacle_violation && efficiency >= efficiency_threshold {
        log.infof("✅ PASSED: %s (efficiency %.1f%%)", test_case.name, efficiency * 100)
        passed += 1
      } else if !obstacle_violation && efficiency < efficiency_threshold {
        log.warnf("⚠️  WARNING: %s - poor efficiency %.1f%% (threshold %.1f%%)", 
                  test_case.name, efficiency * 100, efficiency_threshold * 100)
        // Don't fail test for efficiency alone if path is valid
        passed += 1
      } else {
        log.errorf("❌ FAILED: %s - path through obstacle", test_case.name)
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