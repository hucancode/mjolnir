package tests

import "core:testing"
import "core:log"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Simple test to verify the adjacency fix
@(test)
test_adjacency_simple :: proc(t: ^testing.T) {
  log.info("=== SIMPLE ADJACENCY TEST ===")
  
  // Two triangles sharing an edge
  vertices := [][3]f32{
    {0, 0, 0},  // 0
    {2, 0, 0},  // 1
    {1, 0, 2},  // 2
    {1, 0, -2}, // 3
  }
  
  indices := []u32{
    0, 1, 2,  // Triangle 1
    0, 3, 1,  // Triangle 2 (shared edge 0-1)
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
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh")
  if !ok do return
  
  // Check connectivity
  tile := &navmesh.tiles[0]
  if tile.header == nil {
    testing.expect(t, false, "Should have valid tile")
    return
  }
  
  log.infof("NavMesh has %d polygons", tile.header.poly_count)
  
  // Count links
  total_links := 0
  for i in 0..<tile.header.poly_count {
    link_count := 0
    for link_idx := tile.polys[i].first_link; link_idx != nav.NULL_LINK; {
      if link_idx >= u32(len(tile.links)) do break
      link := &tile.links[link_idx]
      link_count += 1
      total_links += 1
      link_idx = link.next
    }
    log.infof("Polygon %d has %d links", i, link_count)
  }
  
  log.infof("Total links in mesh: %d", total_links)
  
  if total_links > 0 {
    log.info("✅ SUCCESS: Adjacency algorithm is working!")
    
    // Test pathfinding  
    query := nav.query_init(&navmesh)
    defer nav.query_deinit(&query)
    
    path, found := nav.find_path(&query, {-1, 0.1, 0}, {1, 0.1, 0})
    defer if found do delete(path)
    
    log.infof("Pathfinding result: found=%v, waypoints=%d", found, len(path) if found else 0)
    
    testing.expect(t, found, "Should find path with connected mesh")
  } else {
    log.error("❌ FAILED: No connectivity found")
    testing.expect(t, false, "Should have polygon connectivity")
  }
}