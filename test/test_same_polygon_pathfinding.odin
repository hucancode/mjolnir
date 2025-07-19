package tests

import "core:testing"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Test pathfinding within the same polygon
// The issue: when start and end points are in the same polygon,
// the string pulling algorithm creates unnecessary detours
@(test)
test_same_polygon_pathfinding :: proc(t: ^testing.T) {
  log.info("=== SAME POLYGON PATHFINDING TEST ===")
  
  // Create a simple 20x20 ground plane
  vertices := [][3]f32{
    {-10, 0, -10}, // 0
    {10, 0, -10},  // 1
    {10, 0, 10},   // 2
    {-10, 0, 10},  // 3
  }
  
  indices := []u32{
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }
  
  // All triangles are walkable
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  // Build navigation mesh with default config
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3
  config.agent_radius = 0.6
  config.agent_height = 1.5
  config.agent_max_climb = 0.5
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Create query for pathfinding
  query := nav.query_init(&navmesh)
  defer nav.query_deinit(&query)
  
  // Test cases within the same polygon
  test_cases := []struct {
    name: string,
    start: [3]f32,
    end: [3]f32,
    expected_waypoints: int,
    description: string,
  }{
    {
      name = "nearby_points_same_polygon",
      start = {5.0, 0.1, 9.0},
      end = {5.1, 0.1, 9.0},
      expected_waypoints = 2,  // Should be just start and end
      description = "Two points 0.1 units apart in the same polygon should have direct path",
    },
    {
      name = "medium_distance_same_polygon",
      start = {0.0, 0.1, 0.0},
      end = {2.0, 0.1, 2.0},
      expected_waypoints = 2,  // Should be just start and end
      description = "Points within same polygon should have direct path",
    },
    {
      name = "far_points_same_polygon",
      start = {-8.0, 0.1, -8.0},
      end = {8.0, 0.1, 8.0},
      expected_waypoints = 2,  // Should be just start and end
      description = "Even far points in same polygon should have direct path",
    },
    {
      name = "cross_polygon_boundary",
      start = {-5.0, 0.1, 5.0},
      end = {5.0, 0.1, -5.0},
      expected_waypoints = -1,  // Unknown - might cross polygon boundaries
      description = "Path that might cross polygon boundaries after erosion",
    },
  }
  
  log.info("\n=== PATHFINDING TEST CASES ===")
  
  passed := 0
  total := len(test_cases)
  
  for test_case in test_cases {
    log.infof("\n--- %s ---", test_case.name)
    log.infof("Description: %s", test_case.description)
    log.infof("Start: [%.1f, %.1f, %.1f] -> End: [%.1f, %.1f, %.1f]",
              test_case.start.x, test_case.start.y, test_case.start.z,
              test_case.end.x, test_case.end.y, test_case.end.z)
    
    // Find path
    path, found := nav.find_path(&query, test_case.start, test_case.end)
    defer if found do delete(path)
    
    if !found {
      log.error("Failed to find path")
      continue
    }
    
    log.infof("Path found with %d waypoints:", len(path))
    for point, i in path {
      log.infof("  Waypoint %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
    }
    
    // Calculate path distance
    total_distance := f32(0)
    for i in 1..<len(path) {
      total_distance += linalg.distance(path[i-1], path[i])
    }
    
    direct_distance := linalg.distance(test_case.start, test_case.end)
    efficiency := direct_distance / total_distance if total_distance > 0 else 0
    
    log.infof("Path distance: %.3f, Direct distance: %.3f, Efficiency: %.1f%%",
              total_distance, direct_distance, efficiency * 100)
    
    // Check if path is optimal
    if test_case.expected_waypoints == -1 {
      // Unknown expected waypoints - just analyze
      if len(path) == 2 {
        log.infof("✅ OPTIMAL: Direct path with 2 waypoints (same polygon)")
        passed += 1
      } else {
        log.warnf("⚠️  Path has %d waypoints (crosses polygon boundaries)", len(path))
        // Still count as passed since crossing boundaries is valid
        passed += 1
        
        // Show intermediate points
        for i in 1..<len(path)-1 {
          log.infof("  Portal point %d: [%.2f, %.2f, %.2f]",
                    i, path[i].x, path[i].y, path[i].z)
        }
      }
    } else if len(path) == test_case.expected_waypoints {
      log.infof("✅ OPTIMAL: Path has %d waypoints as expected", len(path))
      passed += 1
    } else {
      log.errorf("❌ SUBOPTIMAL: Path has %d waypoints, expected %d", 
                 len(path), test_case.expected_waypoints)
      
      // Analyze why it's suboptimal
      if len(path) > 2 {
        log.info("Path takes unnecessary detour through polygon edges/portals")
        
        // Check if intermediate points are on polygon edges
        for i in 1..<len(path)-1 {
          log.infof("  Intermediate point %d: [%.2f, %.2f, %.2f] (likely on polygon edge)",
                    i, path[i].x, path[i].y, path[i].z)
        }
      }
    }
  }
  
  log.infof("\n=== SAME POLYGON PATH SUMMARY ===")
  log.infof("Passed: %d/%d tests", passed, total)
  
  if passed < total {
    log.info("\nThis is a known issue with the string pulling algorithm.")
    log.info("When both points are in the same polygon, the algorithm")
    log.info("unnecessarily routes through polygon portals instead of")
    log.info("going directly from start to end.")
  }
  
  // This test is expected to fail with current implementation
  // We're documenting the issue rather than fixing it immediately
  testing.expect(t, passed == total, 
                "All paths within same polygon should be optimal (known issue)")
}

// Test to verify polygon structure
@(test) 
test_polygon_structure :: proc(t: ^testing.T) {
  log.info("=== POLYGON STRUCTURE TEST ===")
  
  // Create same simple ground plane
  vertices := [][3]f32{
    {-10, 0, -10}, // 0
    {10, 0, -10},  // 1
    {10, 0, 10},   // 2
    {-10, 0, 10},  // 3
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
  config.cell_size = 0.3
  config.agent_radius = 0.6
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Analyze the polygon structure
  if navmesh.max_tiles > 0 && navmesh.tiles[0].header != nil {
    tile := &navmesh.tiles[0]
    header := tile.header
    
    log.infof("Navigation mesh structure:")
    log.infof("  Polygons: %d", header.poly_count)
    log.infof("  Vertices: %d", header.vert_count)
    
    // Check polygon bounds
    for i in 0..<header.poly_count {
      poly := &tile.polys[i]
      if poly.vert_count == 0 do continue
      
      // Calculate polygon bounds
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
      
      log.infof("  Polygon %d: bounds x[%.1f,%.1f] z[%.1f,%.1f]",
                i, min_bounds.x, max_bounds.x, min_bounds.z, max_bounds.z)
    }
    
    // We expect a single large polygon after erosion
    testing.expect(t, header.poly_count >= 1, 
                  "Should have at least one polygon")
  }
}