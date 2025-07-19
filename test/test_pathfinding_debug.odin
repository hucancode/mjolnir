package tests

import "core:testing"
import "core:log"
import "core:math"
import "core:fmt"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Debug specific failing cases
@(test)
test_pathfinding_debug :: proc(t: ^testing.T) {
  log.info("=== DEBUG FAILING PATHFINDING CASES ===")
  
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
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3
  config.agent_radius = 0.6       // Larger agent radius to prevent narrow corridors
  config.agent_height = 1.5
  config.agent_max_climb = 0.5
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Debug the failing cases
  debug_failing_cases(t, &navmesh)
}

debug_failing_cases :: proc(t: ^testing.T, navmesh: ^nav.NavMesh) {
  query := nav.query_init(navmesh)
  defer nav.query_deinit(&query)
  
  // Debug the 4 failing cases
  failing_cases := []struct {
    name: string,
    start: [3]f32,
    end: [3]f32,
  }{
    {name="corner_bl_to_fr", start={-8, 0.1, 2}, end={8, 0.1, -2}},
    {name="corner_br_to_fl", start={8, 0.1, 2}, end={-8, 0.1, -2}},
    {name="edge_back_traverse", start={-6, 0.1, 1.5}, end={6, 0.1, 1.5}},
    {name="edge_back_traverse_2", start={6, 0.1, 1.5}, end={-6, 0.1, 1.5}},  // Reverse direction
  }
  
  log.info("\n=== DEBUGGING FAILING PATHFINDING CASES ===")
  log.info("Obstacle bounds: x=[-8, 8], z=[-1, 1]")
  
  for test_case in failing_cases {
    log.infof("\n--- DEBUG: %s ---", test_case.name)
    log.infof("Start: [%.1f, %.1f, %.1f] -> End: [%.1f, %.1f, %.1f]",
              test_case.start.x, test_case.start.y, test_case.start.z,
              test_case.end.x, test_case.end.y, test_case.end.z)
    
    // Find start and end polygons
    extent := [3]f32{2, 4, 2}
    start_ref := nav.find_nearest_poly_ref(navmesh, test_case.start, extent)
    end_ref := nav.find_nearest_poly_ref(navmesh, test_case.end, extent)
    
    log.infof("Start poly: %x, End poly: %x", start_ref, end_ref)
    
    // Find path
    path, found := nav.find_path(&query, test_case.start, test_case.end)
    defer if found do delete(path)
    
    if !found {
      log.errorf("❌ NO PATH FOUND")
      continue
    }
    
    log.infof("Path found with %d waypoints", len(path))
    
    // Log full path
    for point, i in path {
      log.infof("  Point %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
      
      // Find which polygon this point belongs to
      poly_ref := nav.find_nearest_poly_ref(navmesh, point, [3]f32{0.1, 0.1, 0.1})
      if poly_ref != 0 {
        log.infof("    -> In polygon %x", poly_ref)
      }
    }
    
    // Check each segment
    obstacle_hit := false
    for i in 1..<len(path) {
      start_seg := path[i-1]
      end_seg := path[i]
      
      log.infof("  Checking segment %d: [%.2f,%.2f,%.2f] -> [%.2f,%.2f,%.2f]",
                i, start_seg.x, start_seg.y, start_seg.z, end_seg.x, end_seg.y, end_seg.z)
      
      // Check if segment intersects obstacle
      if line_intersects_rectangle_2d(start_seg, end_seg, -8, 8, -1, 1) {
        log.errorf("    ❌ INTERSECTS OBSTACLE!")
        obstacle_hit = true
        
        // Calculate intersection details
        dx := end_seg.x - start_seg.x
        dz := end_seg.z - start_seg.z
        
        // Check which edge it might be crossing
        if abs(start_seg.z) > 0.9 && abs(end_seg.z) > 0.9 {
          log.errorf("    Likely crossing near z=1 edge")
        }
        if abs(start_seg.x) > 7 && abs(end_seg.x) > 7 {
          log.errorf("    Likely crossing near x=7.5 edge")
        }
      } else {
        log.infof("    ✅ Clear of obstacle")
      }
    }
    
    if obstacle_hit {
      log.errorf("❌ PATH VIOLATES OBSTACLE CONSTRAINT")
    } else {
      log.infof("✅ PATH IS VALID")
    }
  }
  
  // Also analyze the navigation mesh polygons near the obstacle edges
  log.info("\n=== ANALYZING NAVMESH NEAR OBSTACLE EDGES ===")
  analyze_edge_polygons(navmesh)
}

analyze_edge_polygons :: proc(navmesh: ^nav.NavMesh) {
  if navmesh.max_tiles == 0 || navmesh.tiles[0].header == nil {
    return
  }
  
  tile := &navmesh.tiles[0]
  header := tile.header
  
  log.infof("Analyzing polygons near obstacle edges (obstacle: x=[-7.5,7.5], z=[-1,1])")
  
  // Look for polygons near the obstacle edges
  edge_polygons := 0
  for i in 0..<header.poly_count {
    poly := &tile.polys[i]
    if poly.vert_count == 0 do continue
    
    // Calculate polygon center
    center := [3]f32{}
    min_bounds := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}
    max_bounds := [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
    
    for j in 0..<poly.vert_count {
      vert_idx := poly.verts[j]
      if vert_idx >= u16(header.vert_count) do continue
      
      vert_pos := [3]f32{
        tile.verts[vert_idx * 3 + 0],
        tile.verts[vert_idx * 3 + 1],
        tile.verts[vert_idx * 3 + 2],
      }
      center += vert_pos
      min_bounds = linalg.min(min_bounds, vert_pos)
      max_bounds = linalg.max(max_bounds, vert_pos)
    }
    center /= f32(poly.vert_count)
    
    // Check if polygon is near obstacle edges
    near_edge := false
    edge_desc := ""
    
    // Near back edge (z = 1)
    if abs(center.z - 1.0) < 1.0 && center.x >= -7.5 && center.x <= 7.5 {
      near_edge = true
      edge_desc = fmt.aprintf("near back edge (z~1), center.z=%.2f", center.z)
    } else if abs(center.z + 1.0) < 1.0 && center.x >= -7.5 && center.x <= 7.5 {
      // Near front edge (z = -1)
      near_edge = true
      edge_desc = fmt.aprintf("near front edge (z~-1), center.z=%.2f", center.z)
    } else if abs(center.x + 7.5) < 1.0 && center.z >= -1 && center.z <= 1 {
      // Near left edge (x = -7.5)
      near_edge = true
      edge_desc = fmt.aprintf("near left edge (x~-7.5), center.x=%.2f", center.x)
    } else if abs(center.x - 7.5) < 1.0 && center.z >= -1 && center.z <= 1 {
      // Near right edge (x = 7.5)
      near_edge = true
      edge_desc = fmt.aprintf("near right edge (x~7.5), center.x=%.2f", center.x)
    }
    
    if near_edge {
      log.infof("  Polygon %x %s:", 0x10000 | u32(i), edge_desc)
      log.infof("    Center: [%.2f, %.2f, %.2f]", center.x, center.y, center.z)
      log.infof("    Bounds: x[%.2f,%.2f] z[%.2f,%.2f]", 
                min_bounds.x, max_bounds.x, min_bounds.z, max_bounds.z)
      
      // Check connectivity
      link_count := 0
      for link_idx := poly.first_link; link_idx != nav.NULL_LINK; {
        if link_idx >= u32(len(tile.links)) do break
        link := &tile.links[link_idx]
        link_count += 1
        link_idx = link.next
      }
      log.infof("    Links: %d", link_count)
      edge_polygons += 1
    }
  }
  
  log.infof("Found %d polygons near obstacle edges", edge_polygons)
}