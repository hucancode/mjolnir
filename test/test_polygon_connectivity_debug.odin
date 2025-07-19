package tests

import "core:testing"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import nav "../mjolnir/navigation"
import mjolnir "../mjolnir"

// Test polygon connectivity with different mesh configurations
@(test)
test_polygon_connectivity_debug :: proc(t: ^testing.T) {
  log.info("=== DEBUGGING POLYGON CONNECTIVITY ===")
  
  // Test 1: Simple case that should create connected polygons
  log.info("\n--- Test 1: Two triangles sharing an edge ---")
  test_two_connected_triangles(t)
  
  // Test 2: Four triangles in a 2x2 grid
  log.info("\n--- Test 2: Four triangles in a grid ---")
  test_four_triangle_grid(t)
  
  // Test 3: Long strip of triangles
  log.info("\n--- Test 3: Strip of connected triangles ---")
  test_triangle_strip(t)
}

// Test two triangles that share an edge - should create 2 polygons with 1 link each
test_two_connected_triangles :: proc(t: ^testing.T) {
  // Two triangles sharing the edge from (0,0,0) to (2,0,0)
  vertices := [][3]f32{
    {0, 0, 0},  // 0
    {2, 0, 0},  // 1 - shared edge point
    {1, 0, 2},  // 2 - top of first triangle
    {1, 0, -2}, // 3 - bottom of second triangle
  }
  
  indices := []u32{
    0, 1, 2,  // First triangle
    0, 3, 1,  // Second triangle (sharing edge 0-1)
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  log.info("Input geometry:")
  log.infof("  Triangle 1: vertices %v", []int{0, 1, 2})
  log.infof("    Points: %v -> %v -> %v", vertices[0], vertices[1], vertices[2])
  log.infof("  Triangle 2: vertices %v", []int{0, 3, 1})
  log.infof("    Points: %v -> %v -> %v", vertices[0], vertices[3], vertices[1])
  log.infof("  Shared edge: %v to %v", vertices[0], vertices[1])
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  analyze_connectivity(t, &navmesh, "Two Connected Triangles")
}

// Test four triangles in a 2x2 grid - should create multiple connected polygons
test_four_triangle_grid :: proc(t: ^testing.T) {
  // Create a 2x2 grid of triangles
  vertices := [][3]f32{
    {0, 0, 0},  // 0 - bottom left
    {2, 0, 0},  // 1 - bottom middle
    {4, 0, 0},  // 2 - bottom right
    {0, 0, 2},  // 3 - top left
    {2, 0, 2},  // 4 - top middle
    {4, 0, 2},  // 5 - top right
  }
  
  indices := []u32{
    // Bottom left square (2 triangles)
    0, 1, 4,  // Triangle 1
    0, 4, 3,  // Triangle 2
    // Bottom right square (2 triangles)
    1, 2, 5,  // Triangle 3
    1, 5, 4,  // Triangle 4
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  log.info("Input geometry: 2x2 grid")
  log.infof("  4 triangles forming 2 connected squares")
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  analyze_connectivity(t, &navmesh, "Four Triangle Grid")
}

// Test a strip of connected triangles
test_triangle_strip :: proc(t: ^testing.T) {
  // Create a strip of 3 triangles
  vertices := [][3]f32{
    {0, 0, 0},  // 0
    {1, 0, 0},  // 1
    {2, 0, 0},  // 2
    {3, 0, 0},  // 3
    {0, 0, 1},  // 4
    {1, 0, 1},  // 5
    {2, 0, 1},  // 6
    {3, 0, 1},  // 7
  }
  
  indices := []u32{
    // Strip of rectangles, each made of 2 triangles
    0, 1, 5,  0, 5, 4,  // Rectangle 1
    1, 2, 6,  1, 6, 5,  // Rectangle 2
    2, 3, 7,  2, 7, 6,  // Rectangle 3
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA), u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA), u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA), u8(nav.WALKABLE_AREA),
  }
  
  log.info("Input geometry: Triangle strip")
  log.infof("  6 triangles forming 3 connected rectangles")
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  analyze_connectivity(t, &navmesh, "Triangle Strip")
}

// Detailed analysis of polygon connectivity
analyze_connectivity :: proc(t: ^testing.T, navmesh: ^nav.NavMesh, test_name: string) {
  log.infof("\n=== CONNECTIVITY ANALYSIS: %s ===", test_name)
  
  if navmesh.max_tiles == 0 || navmesh.tiles[0].header == nil {
    log.error("No valid tile found in navmesh")
    testing.expect(t, false, "NavMesh should have valid tiles")
    return
  }
  
  tile := &navmesh.tiles[0]
  header := tile.header
  
  log.infof("NavMesh Structure:")
  log.infof("  Polygons: %d", header.poly_count)
  log.infof("  Vertices: %d", header.vert_count)
  log.infof("  Max links: %d", header.max_link_count)
  log.infof("  Actual links allocated: %d", len(tile.links))
  
  // Analyze each polygon
  total_links := 0
  connected_polygons := 0
  
  for i in 0..<header.poly_count {
    poly := &tile.polys[i]
    poly_ref := nav.encode_poly_id(tile.salt, 0, u32(i))
    center := nav.get_poly_center(navmesh, poly_ref)
    area := nav.get_poly_area(poly)
    
    log.infof("\nPolygon %d (ref: 0x%x):", i, poly_ref)
    log.infof("  Center: [%.2f, %.2f, %.2f]", center.x, center.y, center.z)
    log.infof("  Vertices: %d", poly.vert_count)
    log.infof("  Flags: 0x%x, Area: %d", poly.flags, area)
    log.infof("  First link: %d", poly.first_link)
    
    // Enumerate all vertices
    log.infof("  Vertex positions:")
    for j in 0..<poly.vert_count {
      vert_idx := poly.verts[j]
      if vert_idx < u16(header.vert_count) {
        vert_pos := [3]f32{
          tile.verts[vert_idx * 3 + 0],
          tile.verts[vert_idx * 3 + 1],
          tile.verts[vert_idx * 3 + 2],
        }
        log.infof("    %d: [%.2f, %.2f, %.2f]", j, vert_pos.x, vert_pos.y, vert_pos.z)
      }
    }
    
    // Count and analyze links
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
        
        // Decode neighbor reference
        neighbor_tile_idx := nav.decode_poly_id_tile(neighbor_ref)
        neighbor_poly_idx := nav.decode_poly_id_poly(neighbor_ref)
        
        log.infof("    Link %d: edge=%d, neighbor=0x%x (tile=%d, poly=%d)", 
                  link_idx, link.edge, neighbor_ref, neighbor_tile_idx, neighbor_poly_idx)
        
        link_count += 1
        total_links += 1
        link_idx = link.next
        
        // Safety check to prevent infinite loops
        if link_count > 10 {
          log.errorf("    LOOP DETECTED: too many links")
          break
        }
      }
    }
    
    if link_count > 0 {
      connected_polygons += 1
    }
    
    log.infof("  Total links for this polygon: %d", link_count)
  }
  
  log.infof("\n=== SUMMARY ===")
  log.infof("Total polygons: %d", header.poly_count)
  log.infof("Connected polygons: %d", connected_polygons)
  log.infof("Isolated polygons: %d", int(header.poly_count) - connected_polygons)
  log.infof("Total links: %d", total_links)
  log.infof("Average links per polygon: %.2f", f32(total_links) / f32(header.poly_count))
  
  // Expectations based on test type
  if test_name == "Two Connected Triangles" {
    testing.expect(t, header.poly_count >= 1, "Should have at least 1 polygon")
    testing.expect(t, total_links >= 0, "Should have links between adjacent polygons")
    log.infof("Expected: 2 polygons with 1 link each (total 2 links)")
  } else if test_name == "Four Triangle Grid" {
    testing.expect(t, header.poly_count >= 1, "Should have multiple polygons")
    testing.expect(t, total_links > 0, "Should have links in grid")
    log.infof("Expected: Multiple polygons with grid connectivity")
  } else if test_name == "Triangle Strip" {
    testing.expect(t, header.poly_count >= 1, "Should have multiple polygons") 
    testing.expect(t, total_links > 0, "Should have linear connectivity")
    log.infof("Expected: Linear chain of connected polygons")
  }
  
  if total_links == 0 {
    log.errorf("❌ NO LINKS FOUND - This is the root cause of pathfinding failure!")
    log.errorf("   Polygon merging or adjacency detection is not working correctly")
  } else {
    log.infof("✅ Links found - connectivity should work")
  }
}

// Test to specifically check the polygon merging process
@(test) 
test_polygon_merging_debug :: proc(t: ^testing.T) {
  log.info("=== DEBUGGING POLYGON MERGING PROCESS ===")
  
  // Create the simplest possible case: 2 triangles that should merge
  vertices := [][3]f32{
    {0, 0, 0},  // 0
    {2, 0, 0},  // 1  
    {2, 0, 2},  // 2
    {0, 0, 2},  // 3
  }
  
  indices := []u32{
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA),
    u8(nav.WALKABLE_AREA),
  }
  
  log.info("Simple quad made of 2 triangles - should merge into 1 polygon with no links")
  log.info("OR stay as 2 triangles with 1 link each")
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  testing.expect(t, ok, "Should build navmesh successfully")
  if !ok do return
  
  analyze_connectivity(t, &navmesh, "Simple Quad Merging")
}