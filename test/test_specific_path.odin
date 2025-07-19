package tests

import "../mjolnir"
import "../mjolnir/navigation"
import "core:log"
import "core:math/linalg"
import "core:testing"

// Test the specific path that was reported as suboptimal
@(test)
test_specific_path_with_obstacles :: proc(t: ^testing.T) {
  // Create a scene with obstacles similar to the main application
  ground_size: f32 = 15.0
  obstacle_positions := [][3]f32{
    {0, 0, 0},      // Center obstacle
    {5, 0, 5},      // Northeast
    {-5, 0, -5},    // Southwest
    {10, 0, 0},     // East edge
    {0, 0, -10},    // South edge
    {-10, 0, 0},    // West edge
    {0, 0, 10},     // North edge
    {-8, 0, -8},    // Southwest corner
    {8, 0, 8},      // Northeast corner
    {-3, 0, 7},     // Northwest area
  }
  
  // Build vertices for ground and obstacles
  vertices := make([dynamic][3]f32)
  indices := make([dynamic]u32)
  areas := make([dynamic]u8)
  defer delete(vertices)
  defer delete(indices)
  defer delete(areas)
  
  // Add ground vertices (simple quad)
  append(&vertices, [3]f32{-ground_size, 0, -ground_size})
  append(&vertices, [3]f32{ ground_size, 0, -ground_size})
  append(&vertices, [3]f32{ ground_size, 0,  ground_size})
  append(&vertices, [3]f32{-ground_size, 0,  ground_size})
  
  // Add ground triangles
  append(&indices, 0, 1, 2)
  append(&indices, 0, 2, 3)
  append(&areas, u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA))
  
  // Add obstacle geometry (as non-walkable boxes)
  obstacle_size: f32 = 1.0
  for obstacle_pos in obstacle_positions {
    base_idx := u32(len(vertices))
    
    // Bottom vertices
    append(&vertices, obstacle_pos + [3]f32{-obstacle_size, 0, -obstacle_size})
    append(&vertices, obstacle_pos + [3]f32{ obstacle_size, 0, -obstacle_size})
    append(&vertices, obstacle_pos + [3]f32{ obstacle_size, 0,  obstacle_size})
    append(&vertices, obstacle_pos + [3]f32{-obstacle_size, 0,  obstacle_size})
    
    // Top vertices
    append(&vertices, obstacle_pos + [3]f32{-obstacle_size, 2, -obstacle_size})
    append(&vertices, obstacle_pos + [3]f32{ obstacle_size, 2, -obstacle_size})
    append(&vertices, obstacle_pos + [3]f32{ obstacle_size, 2,  obstacle_size})
    append(&vertices, obstacle_pos + [3]f32{-obstacle_size, 2,  obstacle_size})
    
    // Add faces (all non-walkable)
    // Bottom
    append(&indices, base_idx+0, base_idx+1, base_idx+2)
    append(&indices, base_idx+0, base_idx+2, base_idx+3)
    append(&areas, u8(navigation.NULL_AREA), u8(navigation.NULL_AREA))
    
    // Top
    append(&indices, base_idx+4, base_idx+6, base_idx+5)
    append(&indices, base_idx+4, base_idx+7, base_idx+6)
    append(&areas, u8(navigation.NULL_AREA), u8(navigation.NULL_AREA))
    
    // Sides (4 faces, 2 triangles each)
    // Front
    append(&indices, base_idx+0, base_idx+4, base_idx+5)
    append(&indices, base_idx+0, base_idx+5, base_idx+1)
    append(&areas, u8(navigation.NULL_AREA), u8(navigation.NULL_AREA))
    
    // Right
    append(&indices, base_idx+1, base_idx+5, base_idx+6)
    append(&indices, base_idx+1, base_idx+6, base_idx+2)
    append(&areas, u8(navigation.NULL_AREA), u8(navigation.NULL_AREA))
    
    // Back
    append(&indices, base_idx+2, base_idx+6, base_idx+7)
    append(&indices, base_idx+2, base_idx+7, base_idx+3)
    append(&areas, u8(navigation.NULL_AREA), u8(navigation.NULL_AREA))
    
    // Left
    append(&indices, base_idx+3, base_idx+7, base_idx+4)
    append(&indices, base_idx+3, base_idx+4, base_idx+0)
    append(&areas, u8(navigation.NULL_AREA), u8(navigation.NULL_AREA))
  }
  
  input := navigation.NavMeshInput{
    vertices = vertices[:],
    indices = indices[:],
    areas = areas[:],
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3
  config.agent_radius = 0.6
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh with obstacles should build")
  defer navigation.destroy(&navmesh)
  
  if ok {
    query := navigation.query_init(&navmesh)
    defer navigation.query_deinit(&query)
    
    // Test the specific path from the log
    start := [3]f32{1.95, 0.1, 4.45}
    end := [3]f32{-11.06, 0.1, 4.02}
    
    // First get the polygon path to understand the route
    start_ref := navigation.find_nearest_poly_ref(&navmesh, start, [3]f32{2, 2, 2})
    end_ref := navigation.find_nearest_poly_ref(&navmesh, end, [3]f32{2, 2, 2})
    
    log.infof("Start poly ref: %x, End poly ref: %x", start_ref, end_ref)
    
    path, found := navigation.find_path(&query, start, end)
    testing.expect(t, found, "Should find path around obstacles")
    
    if found {
      defer delete(path)
      
      log.infof("Path from [%.2f, %.2f, %.2f] to [%.2f, %.2f, %.2f] has %d waypoints:",
        start.x, start.y, start.z, end.x, end.y, end.z, len(path))
      
      for waypoint, i in path {
        log.infof("  Waypoint %d: [%.2f, %.2f, %.2f]", i, waypoint.x, waypoint.y, waypoint.z)
      }
      
      // Check if the path avoids the center obstacle
      center_obstacle := [3]f32{0, 0, 0}
      obstacle_radius: f32 = 1.0 + config.agent_radius
      
      for waypoint, i in path[1:len(path)-1] {  // Skip start/end
        dist_to_center := linalg.distance(
          [2]f32{waypoint.x, waypoint.z},
          [2]f32{center_obstacle.x, center_obstacle.z}
        )
        
        testing.expectf(t, dist_to_center >= obstacle_radius,
          "Waypoint %d should avoid center obstacle (dist=%.2f, min=%.2f)",
          i, dist_to_center, obstacle_radius)
      }
      
      // The path going to positive X first might be optimal if it needs to avoid the center
      // Let's check if a direct path would hit the obstacle
      direct_would_hit := check_line_hits_obstacle(start, end, center_obstacle, obstacle_radius)
      if direct_would_hit {
        log.info("Direct path would hit center obstacle - detour is necessary")
      } else {
        log.info("Direct path would be clear - current path may be suboptimal")
      }
    }
  }
}

// Check if a line segment intersects with a circular obstacle
check_line_hits_obstacle :: proc(start, end: [3]f32, obstacle: [3]f32, radius: f32) -> bool {
  // Project to 2D (XZ plane)
  p1 := [2]f32{start.x, start.z}
  p2 := [2]f32{end.x, end.z}
  center := [2]f32{obstacle.x, obstacle.z}
  
  // Vector from p1 to p2
  d := p2 - p1
  // Vector from p1 to center
  f := p1 - center
  
  // Quadratic formula coefficients for line-circle intersection
  a := linalg.dot(d, d)
  b := 2 * linalg.dot(f, d)
  c := linalg.dot(f, f) - radius * radius
  
  discriminant := b * b - 4 * a * c
  if discriminant < 0 {
    return false  // No intersection
  }
  
  // Check if intersection points are within the line segment
  discriminant = linalg.sqrt(discriminant)
  t1 := (-b - discriminant) / (2 * a)
  t2 := (-b + discriminant) / (2 * a)
  
  // If either intersection point is within [0, 1], the segment hits the circle
  return (t1 >= 0 && t1 <= 1) || (t2 >= 0 && t2 <= 1) || (t1 < 0 && t2 > 1)
}