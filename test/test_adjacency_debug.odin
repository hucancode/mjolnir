package tests

import "core:testing"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Debug test specifically for the adjacency building function
@(test)
test_adjacency_debug :: proc(t: ^testing.T) {
  log.info("=== ADJACENCY DEBUG TEST ===")
  
  // Create a very simple test case: 2 triangles that share an edge
  vertices := [][3]f32{
    {0, 0, 0},  // 0
    {2, 0, 0},  // 1 - shared edge start
    {1, 0, 2},  // 2 - first triangle apex
    {1, 0, -2}, // 3 - second triangle apex
  }
  
  indices := []u32{
    0, 1, 2,  // First triangle: (0,1,2)
    1, 3, 0,  // Second triangle: (1,3,0) - shares edge (0,1)
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  log.info("Creating simple adjacency test case:")
  log.infof("  Triangle 1: vertices 0-1-2 (%v-%v-%v)", vertices[0], vertices[1], vertices[2])
  log.infof("  Triangle 2: vertices 1-3-0 (%v-%v-%v)", vertices[1], vertices[3], vertices[0])
  log.infof("  Shared edge: 0-1 (%v-%v)", vertices[0], vertices[1])
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.5  // Larger cell size for simpler mesh
  
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  // Analyze the resulting mesh structure
  analyze_adjacency_detailed(t, &navmesh, "Simple Two Triangle Test")
}

// Detailed adjacency analysis with step-by-step debugging
analyze_adjacency_detailed :: proc(t: ^testing.T, navmesh: ^nav.NavMesh, test_name: string) {
  log.infof("\n=== DETAILED ADJACENCY ANALYSIS: %s ===", test_name)
  
  if navmesh.max_tiles == 0 || navmesh.tiles[0].header == nil {
    log.error("No valid tile found in navmesh")
    testing.expect(t, false, "NavMesh should have valid tiles")
    return
  }
  
  tile := &navmesh.tiles[0]
  header := tile.header
  
  log.infof("Mesh Structure:")
  log.infof("  Polygons: %d", header.poly_count)
  log.infof("  Vertices: %d", header.vert_count)
  log.infof("  Links allocated: %d", len(tile.links))
  
  // Print all vertices
  log.infof("\nAll Vertices:")
  for i in 0..<header.vert_count {
    v_idx := i * 3
    pos := [3]f32{
      tile.verts[v_idx + 0],
      tile.verts[v_idx + 1],
      tile.verts[v_idx + 2],
    }
    log.infof("  Vertex %d: [%.2f, %.2f, %.2f]", i, pos.x, pos.y, pos.z)
  }
  
  // Analyze each polygon in detail
  log.infof("\nPolygon Analysis:")
  for i in 0..<header.poly_count {
    poly := &tile.polys[i]
    poly_ref := nav.encode_poly_id(tile.salt, 0, u32(i))
    
    log.infof("\nPolygon %d (ref: 0x%x):", i, poly_ref)
    log.infof("  Vertex count: %d", poly.vert_count)
    log.infof("  Flags: 0x%x", poly.flags)
    log.infof("  First link: %d", poly.first_link)
    
    // List all vertices
    log.infof("  Vertices:")
    for j in 0..<poly.vert_count {
      vert_idx := poly.verts[j]
      if vert_idx < u16(header.vert_count) {
        v_pos_idx := vert_idx * 3
        pos := [3]f32{
          tile.verts[v_pos_idx + 0],
          tile.verts[v_pos_idx + 1],
          tile.verts[v_pos_idx + 2],
        }
        log.infof("    %d: vertex %d at [%.2f, %.2f, %.2f]", j, vert_idx, pos.x, pos.y, pos.z)
      } else {
        log.errorf("    %d: INVALID vertex index %d", j, vert_idx)
      }
    }
    
    // List all edges and their adjacency info
    log.infof("  Edges:")
    for j in 0..<poly.vert_count {
      v0_idx := poly.verts[j]
      v1_idx := poly.verts[(j + 1) % poly.vert_count]
      
      // Get neighbor info
      neighbor_idx := get_polygon_neighbor(tile, i, i32(j))
      neighbor_str := neighbor_idx == 0xffff ? "NONE" : ""
      if neighbor_idx != 0xffff {
        neighbor_str = "Connected"
      }
      
      log.infof("    Edge %d: v%d->v%d, neighbor: %s", j, v0_idx, v1_idx, neighbor_str)
    }
    
    // Count and list links
    link_count := 0
    log.infof("  Links:")
    if poly.first_link == nav.NULL_LINK {
      log.infof("    No links (first_link = NULL_LINK)")
    } else {
      for link_idx := poly.first_link; link_idx != nav.NULL_LINK; {
        if link_idx >= u32(len(tile.links)) {
          log.errorf("    INVALID LINK INDEX: %d >= %d", link_idx, len(tile.links))
          break
        }
        
        link := &tile.links[link_idx]
        neighbor_ref := link.ref
        
        neighbor_tile_idx := nav.decode_poly_id_tile(neighbor_ref)
        neighbor_poly_idx := nav.decode_poly_id_poly(neighbor_ref)
        
        log.infof("    Link %d: edge=%d, neighbor=0x%x (tile=%d, poly=%d)", 
                  link_idx, link.edge, neighbor_ref, neighbor_tile_idx, neighbor_poly_idx)
        
        link_count += 1
        link_idx = link.next
        
        if link_count > 10 {
          log.errorf("    LOOP DETECTED: too many links")
          break
        }
      }
    }
    
    log.infof("  Total links: %d", link_count)
  }
  
  // Check for edge matching between polygons
  log.infof("\nEdge Matching Analysis:")
  for i in 0..<header.poly_count {
    poly_i := &tile.polys[i]
    for j in 0..<poly_i.vert_count {
      v0 := poly_i.verts[j]
      v1 := poly_i.verts[(j + 1) % poly_i.vert_count]
      
      // Look for matching edge in other polygons
      for k in i+1..<header.poly_count {
        poly_k := &tile.polys[k]
        for m in 0..<poly_k.vert_count {
          w0 := poly_k.verts[m]
          w1 := poly_k.verts[(m + 1) % poly_k.vert_count]
          
          // Check if edges match (v0-v1 vs w1-w0)
          if v0 == w1 && v1 == w0 {
            log.infof("  Edge match found: poly %d edge %d (%d->%d) matches poly %d edge %d (%d->%d)", 
                      i, j, v0, v1, k, m, w0, w1)
            
            // Check if they're actually connected in the adjacency data
            neighbor_from_i := get_polygon_neighbor(tile, i, i32(j))
            neighbor_from_k := get_polygon_neighbor(tile, k, i32(m))
            
            expected_i := u16(k + 1)  // 1-based indexing
            expected_k := u16(i + 1)  // 1-based indexing
            
            if neighbor_from_i == expected_i && neighbor_from_k == expected_k {
              log.infof("    ✓ Correctly connected in adjacency data")
            } else {
              log.errorf("    ✗ NOT connected in adjacency data: %d->%d, %d->%d", 
                         neighbor_from_i, expected_i, neighbor_from_k, expected_k)
            }
          }
        }
      }
    }
  }
  
  // Summary
  total_polygons := int(header.poly_count)
  connected_polygons := 0
  total_links := 0
  
  for i in 0..<header.poly_count {
    poly := &tile.polys[i]
    poly_link_count := 0
    
    for link_idx := poly.first_link; link_idx != nav.NULL_LINK; {
      if link_idx >= u32(len(tile.links)) do break
      link := &tile.links[link_idx]
      poly_link_count += 1
      total_links += 1
      link_idx = link.next
    }
    
    if poly_link_count > 0 {
      connected_polygons += 1
    }
  }
  
  log.infof("\n=== ADJACENCY SUMMARY ===")
  log.infof("Total polygons: %d", total_polygons)
  log.infof("Connected polygons: %d", connected_polygons)
  log.infof("Isolated polygons: %d", total_polygons - connected_polygons)
  log.infof("Total links: %d", total_links)
  
  if total_links == 0 {
    log.errorf("❌ NO CONNECTIVITY - This explains pathfinding failure!")
    log.errorf("   Issue is in the mesh adjacency building process")
    testing.expect(t, false, "Should have polygon connectivity")
  } else {
    log.infof("✅ Connectivity found")
  }
}

// Get the neighbor of a polygon edge by accessing the mesh structure directly
get_polygon_neighbor :: proc(tile: ^nav.MeshTile, poly_idx: i32, edge_idx: i32) -> u16 {
  if poly_idx < 0 || poly_idx >= i32(tile.header.poly_count) {
    return 0xffff
  }
  
  poly := &tile.polys[poly_idx]
  if edge_idx < 0 || edge_idx >= i32(poly.vert_count) {
    return 0xffff
  }
  
  // Return the neighbor value stored in the polygon
  // Note: neis stores 1-based indices, 0 means no neighbor
  return poly.neis[edge_idx]
}