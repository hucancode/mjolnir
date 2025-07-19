package tests

import "core:testing"
import "core:log"
import "core:math"
import "core:fmt"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Test navigation mesh connectivity to find invalid connections
@(test)
test_navmesh_connectivity :: proc(t: ^testing.T) {
  log.info("=== NAVIGATION MESH CONNECTIVITY ANALYSIS ===")
  
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
  config.agent_radius = 0.6       // Larger agent radius to prevent narrow corridors
  config.agent_height = 1.5
  config.agent_max_climb = 0.5
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Analyze connectivity
  analyze_navmesh_connectivity(&navmesh)
}

analyze_navmesh_connectivity :: proc(navmesh: ^nav.NavMesh) {
  if navmesh.max_tiles == 0 || navmesh.tiles[0].header == nil {
    return
  }
  
  tile := &navmesh.tiles[0]
  header := tile.header
  
  log.infof("Navigation mesh has %d polygons", header.poly_count)
  log.info("Obstacle bounds: x=[-8, 8], z=[-1, 1]")
  
  // Check each polygon
  for i in 0..<header.poly_count {
    poly := &tile.polys[i]
    if poly.vert_count == 0 do continue
    
    // Calculate polygon center and bounds
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
    
    // Determine which side of obstacle this polygon is on
    side := "unknown"
    if center.z < -1 {
      side = "front (z < -1)"
    } else if center.z > 1 {
      side = "back (z > 1)"
    } else if center.x < -8 {
      side = "left (x < -8)"
    } else if center.x > 8 {
      side = "right (x > 8)"
    } else if center.z >= -1 && center.z <= 1 && center.x >= -8 && center.x <= 8 {
      side = "INSIDE OBSTACLE!"
    } else {
      side = "transitional"
    }
    
    // Check connections
    connections := make([dynamic]nav.PolyRef)
    defer delete(connections)
    
    for link_idx := poly.first_link; link_idx != nav.NULL_LINK; {
      if link_idx >= u32(len(tile.links)) do break
      link := &tile.links[link_idx]
      append(&connections, link.ref)
      link_idx = link.next
    }
    
    if len(connections) > 0 || side == "INSIDE OBSTACLE!" {
      log.infof("\nPolygon %x:", 0x10000 | u32(i))
      log.infof("  Center: [%.2f, %.2f, %.2f]", center.x, center.y, center.z)
      log.infof("  Bounds: x[%.2f,%.2f] z[%.2f,%.2f]", 
                min_bounds.x, max_bounds.x, min_bounds.z, max_bounds.z)
      log.infof("  Side: %s", side)
      log.infof("  Connections: %d", len(connections))
      
      // Check each connection
      for conn_ref in connections {
        conn_idx := nav.decode_poly_id_poly(conn_ref)
        if conn_idx >= u32(header.poly_count) do continue
        
        conn_poly := &tile.polys[conn_idx]
        conn_center := [3]f32{}
        for j in 0..<conn_poly.vert_count {
          vert_idx := conn_poly.verts[j]
          if vert_idx >= u16(header.vert_count) do continue
          vert_pos := [3]f32{
            tile.verts[vert_idx * 3 + 0],
            tile.verts[vert_idx * 3 + 1],
            tile.verts[vert_idx * 3 + 2],
          }
          conn_center += vert_pos
        }
        conn_center /= f32(conn_poly.vert_count)
        
        // Check if this connection crosses the obstacle
        crosses_obstacle := false
        
        // Simple check: if one polygon is in front (z < -1) and other is in back (z > 1)
        if (center.z < -1 && conn_center.z > 1) || (center.z > 1 && conn_center.z < -1) {
          // Check if the line between centers passes through obstacle bounds
          if line_intersects_rectangle_2d(center, conn_center, -8, 8, -1, 1) {
            crosses_obstacle = true
          }
        }
        
        if crosses_obstacle {
          log.errorf("    -> Connected to %x at [%.2f,%.2f,%.2f] CROSSES OBSTACLE!", 
                    conn_ref, conn_center.x, conn_center.y, conn_center.z)
        } else {
          log.infof("    -> Connected to %x at [%.2f,%.2f,%.2f]", 
                   conn_ref, conn_center.x, conn_center.y, conn_center.z)
        }
      }
    }
  }
  
  // Look for specific problematic connections
  log.info("\n=== CHECKING SPECIFIC PROBLEMATIC CONNECTIONS ===")
  
  // Find polygons at corners that might have invalid connections
  for i in 0..<header.poly_count {
    poly := &tile.polys[i]
    if poly.vert_count == 0 do continue
    
    center := nav.get_poly_center(navmesh, nav.encode_poly_id(tile.salt, 0, u32(i)))
    
    // Check if this is near a corner where we expect problems
    near_problem_corner := false
    corner_desc := ""
    
    if abs(center.x + 9) < 1 && abs(center.z - 3) < 1 {
      near_problem_corner = true
      corner_desc = "bottom-left corner (-9, 3)"
    } else if abs(center.x - 9) < 1 && abs(center.z - 3) < 1 {
      near_problem_corner = true
      corner_desc = "bottom-right corner (9, 3)"
    } else if abs(center.x + 9) < 1 && abs(center.z + 3) < 1 {
      near_problem_corner = true
      corner_desc = "top-left corner (-9, -3)"
    } else if abs(center.x - 9) < 1 && abs(center.z + 3) < 1 {
      near_problem_corner = true
      corner_desc = "top-right corner (9, -3)"
    }
    
    if near_problem_corner {
      log.infof("\nPolygon %x near %s:", 0x10000 | u32(i), corner_desc)
      log.infof("  Center: [%.2f, %.2f, %.2f]", center.x, center.y, center.z)
      
      // Check all connections from this polygon
      for link_idx := poly.first_link; link_idx != nav.NULL_LINK; {
        if link_idx >= u32(len(tile.links)) do break
        link := &tile.links[link_idx]
        
        conn_center := nav.get_poly_center(navmesh, link.ref)
        
        // Check if connection spans across the obstacle
        if line_intersects_rectangle_2d(center, conn_center, -8, 8, -1, 1) {
          log.errorf("  ❌ INVALID CONNECTION to %x at [%.2f,%.2f,%.2f] - crosses obstacle!", 
                    link.ref, conn_center.x, conn_center.y, conn_center.z)
        }
        
        link_idx = link.next
      }
    }
  }
}