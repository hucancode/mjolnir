package tests

import "core:testing"
import "core:log"
import "core:math"
import "core:fmt"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Debug the specific failing corner cases
@(test)
test_corner_debug :: proc(t: ^testing.T) {
  log.info("=== DEBUG CORNER CASE PATHFINDING ===")
  
  // Create scene with obstacle
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
  
  // Create areas
  areas := make([]u8, len(indices) / 3)
  defer delete(areas)
  
  ground_triangle_count := len(ground_indices) / 3
  obstacle_triangle_count := len(obstacle_indices) / 3
  
  for i in 0..<ground_triangle_count {
    areas[i] = u8(nav.WALKABLE_AREA)
  }
  
  for i in 0..<obstacle_triangle_count {
    areas[ground_triangle_count + i] = u8(nav.NULL_AREA)
  }
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3
  config.agent_radius = 0.1
  config.agent_height = 1.5
  config.agent_max_climb = 0.5
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Debug the specific failing corner cases
  debug_corner_cases(t, &navmesh)
}

debug_corner_cases :: proc(t: ^testing.T, navmesh: ^nav.NavMesh) {
  query := nav.query_init(navmesh)
  defer nav.query_deinit(&query)
  
  // Test the two failing corner cases
  test_cases := []struct {
    name: string,
    start: [3]f32,
    end: [3]f32,
  }{
    {name="corner_bl_to_fr", start={-9, 0.1, 3}, end={9, 0.1, -3}},
    {name="corner_br_to_fl", start={9, 0.1, 3}, end={-9, 0.1, -3}},
  }
  
  for test_case in test_cases {
    log.infof("\n=== DEBUG: %s ===", test_case.name)
    log.infof("Start: [%.1f, %.1f, %.1f] -> End: [%.1f, %.1f, %.1f]",
              test_case.start.x, test_case.start.y, test_case.start.z,
              test_case.end.x, test_case.end.y, test_case.end.z)
    
    // Find start and end polygons
    extent := [3]f32{2, 4, 2}
    start_ref := nav.find_nearest_poly_ref(navmesh, test_case.start, extent)
    end_ref := nav.find_nearest_poly_ref(navmesh, test_case.end, extent)
    
    log.infof("Start poly: %x, End poly: %x", start_ref, end_ref)
    
    if start_ref == end_ref {
      log.warnf("Start and end are in the SAME polygon! This explains the direct path.")
      continue
    }
    
    // Find polygon path using internal function
    poly_path := nav.find_polygon_path(&query, start_ref, end_ref, test_case.start, test_case.end)
    defer if len(poly_path) > 0 do delete(poly_path)
    
    log.infof("Polygon path length: %d", len(poly_path))
    for poly_ref, i in poly_path {
      center := nav.get_poly_center(navmesh, poly_ref)
      log.infof("  Poly %d: %x at [%.2f, %.2f, %.2f]", i, poly_ref, center.x, center.y, center.z)
    }
    
    // Try string pulling
    if len(poly_path) > 0 {
      path := nav.string_pull_path(navmesh, poly_path, test_case.start, test_case.end)
      defer if len(path) > 0 do delete(path)
      
      log.infof("String pulled path: %d waypoints", len(path))
      for point, i in path {
        log.infof("  Point %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
      }
      
      // Check if path cuts through obstacle
      if len(path) >= 2 {
        for i in 1..<len(path) {
          if line_intersects_rectangle_2d(path[i-1], path[i], -7.5, 7.5, -1, 1) {
            log.errorf("  ❌ Segment %d CUTS THROUGH OBSTACLE!", i)
          }
        }
      }
    }
  }
}