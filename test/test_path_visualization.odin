package tests

import "../mjolnir"
import "../mjolnir/navigation"
import "core:log"
import "core:math/linalg"
import "core:testing"
import "core:fmt"

// Test to visualize why certain paths are suboptimal
@(test)
test_path_visualization :: proc(t: ^testing.T) {
  // Create a simple scene to understand path behavior
  vertices := make([dynamic][3]f32)
  indices := make([dynamic]u32)
  areas := make([dynamic]u8)
  defer delete(vertices)
  defer delete(indices)
  defer delete(areas)
  
  // Create a large ground plane
  ground_size: f32 = 15.0
  
  // Add ground vertices (subdivided for better navigation mesh)
  subdivisions := 10
  cell_size := ground_size * 2 / f32(subdivisions)
  
  for y in 0..=subdivisions {
    for x in 0..=subdivisions {
      vx := -ground_size + f32(x) * cell_size
      vz := -ground_size + f32(y) * cell_size
      append(&vertices, [3]f32{vx, 0, vz})
    }
  }
  
  // Generate ground triangles
  for y in 0..<subdivisions {
    for x in 0..<subdivisions {
      base := u32(y * (subdivisions + 1) + x)
      // First triangle
      append(&indices, base, base + 1, base + u32(subdivisions) + 1)
      append(&areas, u8(navigation.WALKABLE_AREA))
      // Second triangle  
      append(&indices, base, base + u32(subdivisions) + 1, base + u32(subdivisions) + 2)
      append(&areas, u8(navigation.WALKABLE_AREA))
    }
  }
  
  log.infof("Created ground with %d vertices, %d triangles", len(vertices), len(areas))
  
  // Build navigation mesh
  input := navigation.NavMeshInput{
    vertices = vertices[:],
    indices = indices[:],
    areas = areas[:],
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.5
  config.agent_radius = 0.6
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh should build")
  defer navigation.destroy(&navmesh)
  
  if ok {
    // Count polygons
    poly_count := 0
    for &tile in navmesh.tiles {
      if tile.header != nil {
        poly_count += int(tile.header.poly_count)
      }
    }
    log.infof("Navigation mesh has %d polygons", poly_count)
    
    query := navigation.query_init(&navmesh)
    defer navigation.query_deinit(&query)
    
    // Test the specific problematic path
    test_cases := []struct {
      name: string,
      start: [3]f32,
      end: [3]f32,
    }{
      {"Northwest to center", {-9.9, 0.1, 9.5}, {-0.5, 0.1, 1.5}},
      {"Direct horizontal", {-10, 0.1, 0}, {10, 0.1, 0}},
      {"Direct diagonal", {-10, 0.1, -10}, {10, 0.1, 10}},
      {"Around center", {-5, 0.1, 0}, {5, 0.1, 0}},
    }
    
    for test_case in test_cases {
      log.infof("\n=== Test: %s ===", test_case.name)
      log.infof("From [%.1f, %.1f, %.1f] to [%.1f, %.1f, %.1f]",
        test_case.start.x, test_case.start.y, test_case.start.z,
        test_case.end.x, test_case.end.y, test_case.end.z)
      
      // Find polygon path first
      start_ref := navigation.find_nearest_poly_ref(&navmesh, test_case.start, [3]f32{2, 2, 2})
      end_ref := navigation.find_nearest_poly_ref(&navmesh, test_case.end, [3]f32{2, 2, 2})
      
      if start_ref != 0 && end_ref != 0 {
        poly_path := navigation.find_polygon_path(&query, start_ref, end_ref, test_case.start, test_case.end)
        defer delete(poly_path)
        
        log.infof("Polygon path length: %d", len(poly_path))
        
        // Get string-pulled path
        path, found := navigation.find_path(&query, test_case.start, test_case.end)
        
        if found {
          defer delete(path)
          log.infof("String-pulled path has %d waypoints:", len(path))
          
          total_distance: f32 = 0
          for i in 0..<len(path)-1 {
            segment_dist := linalg.distance(path[i], path[i+1])
            total_distance += segment_dist
            log.infof("  %d: [%.2f, %.2f, %.2f] -> [%.2f, %.2f, %.2f] (dist: %.2f)",
              i, path[i].x, path[i].y, path[i].z,
              path[i+1].x, path[i+1].y, path[i+1].z,
              segment_dist)
          }
          
          direct_distance := linalg.distance(test_case.start, test_case.end)
          efficiency := direct_distance / total_distance * 100
          
          log.infof("Path efficiency: %.1f%% (direct: %.2f, actual: %.2f)",
            efficiency, direct_distance, total_distance)
          
          // Check if path is reasonably optimal (within 10% of direct distance)
          is_optimal := efficiency >= 90.0
          testing.expectf(t, is_optimal || len(path) <= 3,
            "%s: Path efficiency %.1f%% is too low", test_case.name, efficiency)
        }
      }
    }
    
    // Analyze mesh structure
    log.info("\n=== Navigation Mesh Analysis ===")
    
    // Look at polygon connectivity
    total_links := 0
    isolated_polys := 0
    max_neighbors := 0
    
    for &tile in navmesh.tiles {
      if tile.header == nil do continue
      
      for i in 0..<tile.header.poly_count {
        poly := &tile.polys[i]
        neighbor_count := 0
        
        // Count neighbors through links
        for link_idx := poly.first_link; link_idx != navigation.NULL_LINK; {
          if link_idx >= u32(len(tile.links)) do break
          link := &tile.links[link_idx]
          if link.ref != 0 do neighbor_count += 1
          link_idx = link.next
          total_links += 1
        }
        
        if neighbor_count == 0 do isolated_polys += 1
        if neighbor_count > max_neighbors do max_neighbors = neighbor_count
      }
    }
    
    log.infof("Total links: %d", total_links)
    log.infof("Isolated polygons: %d", isolated_polys)
    log.infof("Max neighbors per polygon: %d", max_neighbors)
    
    testing.expect(t, isolated_polys == 0, "No polygons should be isolated")
  }
}

// Helper to visualize polygon adjacency
visualize_polygon_at :: proc(navmesh: ^navigation.NavMesh, pos: [3]f32) {
  poly_ref := navigation.find_nearest_poly_ref(navmesh, pos, [3]f32{1, 1, 1})
  if poly_ref == 0 {
    log.warnf("No polygon found at position [%.1f, %.1f, %.1f]", pos.x, pos.y, pos.z)
    return
  }
  
  tile_idx := navigation.decode_poly_id_tile(poly_ref)
  poly_idx := navigation.decode_poly_id_poly(poly_ref)
  
  if tile_idx >= u32(navmesh.max_tiles) do return
  
  tile := &navmesh.tiles[tile_idx]
  if tile.header == nil || poly_idx >= u32(tile.header.poly_count) do return
  
  poly := &tile.polys[poly_idx]
  
  log.infof("Polygon at [%.1f, %.1f, %.1f]:", pos.x, pos.y, pos.z)
  log.infof("  Ref: %x, Vertices: %d", poly_ref, poly.vert_count)
  
  // Show vertices
  for i in 0..<poly.vert_count {
    vert_idx := poly.verts[i]
    if vert_idx >= u16(tile.header.vert_count) do continue
    
    vx := tile.verts[vert_idx * 3 + 0]
    vy := tile.verts[vert_idx * 3 + 1]
    vz := tile.verts[vert_idx * 3 + 2]
    log.infof("  Vertex %d: [%.2f, %.2f, %.2f]", i, vx, vy, vz)
  }
  
  // Show neighbors
  neighbor_count := 0
  for link_idx := poly.first_link; link_idx != navigation.NULL_LINK; {
    if link_idx >= u32(len(tile.links)) do break
    link := &tile.links[link_idx]
    
    if link.ref != 0 {
      neighbor_tile := navigation.decode_poly_id_tile(link.ref)
      neighbor_poly := navigation.decode_poly_id_poly(link.ref)
      log.infof("  Neighbor %d: poly %x (tile %d, poly %d) via edge %d",
        neighbor_count, link.ref, neighbor_tile, neighbor_poly, link.edge)
      neighbor_count += 1
    }
    
    link_idx = link.next
  }
}