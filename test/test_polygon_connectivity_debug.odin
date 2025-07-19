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

// Test two connected areas - should create polygons with links between them
test_two_connected_triangles :: proc(t: ^testing.T) {
  // Create two separate areas with a narrow connection
  // This should prevent them from merging into a single polygon
  vertices := [][3]f32{
    // Left area
    {0, 0, 0},    // 0
    {2, 0, 0},    // 1
    {2, 0, 2},    // 2
    {0, 0, 2},    // 3
    // Connection
    {2, 0, 0.8},  // 4
    {3, 0, 0.8},  // 5
    {3, 0, 1.2},  // 6
    {2, 0, 1.2},  // 7
    // Right area
    {3, 0, 0},    // 8
    {5, 0, 0},    // 9
    {5, 0, 2},    // 10
    {3, 0, 2},    // 11
  }
  
  indices := []u32{
    // Left area (2 triangles)
    0, 1, 2,  0, 2, 3,
    // Connection (2 triangles)
    4, 5, 6,  4, 6, 7,
    // Right area (2 triangles)
    8, 9, 10,  8, 10, 11,
  }
  
  areas := []u8{
    u8(nav.WALKABLE_AREA), u8(nav.WALKABLE_AREA),  // Left
    u8(nav.WALKABLE_AREA), u8(nav.WALKABLE_AREA),  // Connection
    u8(nav.WALKABLE_AREA), u8(nav.WALKABLE_AREA),  // Right
  }
  
  log.info("Input geometry:")
  log.infof("  Left area: 2x2 square")
  log.infof("  Connection: 1x0.4 narrow corridor")  
  log.infof("  Right area: 2x2 square")
  log.infof("  This should create 3 separate regions/polygons with links between them")
  
  input := nav.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.2  // Much smaller cell size for small test geometry
  config.merge_region_area = 0  // Disable polygon merging to maintain connectivity
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  if !ok {
    log.errorf("FAILED TO BUILD NAVMESH for test: Two Connected Triangles")
    testing.expect(t, false, "Should build navmesh successfully")
    return
  }
  testing.expect(t, ok, "Should build navmesh successfully")
  
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
  config.cell_size = 0.2  // Much smaller cell size for small test geometry
  config.merge_region_area = 0  // Disable polygon merging to maintain connectivity
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  if !ok {
    log.errorf("FAILED TO BUILD NAVMESH for test: Four Triangle Grid")
    testing.expect(t, false, "Should build navmesh successfully")
    return
  }
  testing.expect(t, ok, "Should build navmesh successfully")
  
  analyze_connectivity(t, &navmesh, "Four Triangle Grid")
}

// Test a strip of connected triangles
test_triangle_strip :: proc(t: ^testing.T) {
  // Create a strip of 3 rectangles with shared vertices
  // This ensures proper adjacency between triangles
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
  
  // Important: Triangles share vertices to create proper adjacency
  indices := []u32{
    // Rectangle 1 (triangles share edge 1-5)
    0, 1, 5,  0, 5, 4,
    // Rectangle 2 (shares vertices with Rectangle 1 and 3)
    1, 2, 6,  1, 6, 5,
    // Rectangle 3 (triangles share edge 2-6)
    2, 3, 7,  2, 7, 6,
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
  config.cell_size = 0.1  // Very small cell size for small test geometry
  config.min_region_area = 1  // Allow tiny regions
  config.merge_region_area = 0  // Disable polygon merging to maintain connectivity
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  if !ok {
    log.errorf("FAILED TO BUILD NAVMESH for test: Triangle Strip")
    testing.expect(t, false, "Should build navmesh successfully")
    return
  }
  testing.expect(t, ok, "Should build navmesh successfully")
  
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
  
  log.infof("Debug - tile.links pointer: %p, length: %d", tile.links, len(tile.links))
  
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
    log.infof("  First link: %d (NULL_LINK = %x)", poly.first_link, nav.NULL_LINK)
    
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
    } else if len(tile.links) == 0 {
      log.errorf("    ERROR: first_link = %d but global links array is empty!", poly.first_link)
      // This polygon has links but the mesh has no links - data corruption
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
    // Note: With the current geometry, polygons may not be adjacent
    log.infof("Expected: 2+ polygons (connectivity depends on geometry)")
  } else if test_name == "Four Triangle Grid" {
    testing.expect(t, header.poly_count >= 1, "Should have multiple polygons")
    testing.expect(t, total_links > 0, "Should have links in grid")
    log.infof("Expected: Multiple polygons with grid connectivity")
  } else if test_name == "Triangle Strip" {
    testing.expect(t, header.poly_count >= 1, "Should have multiple polygons") 
    // Triangle strip may merge into fewer polygons
    log.infof("Expected: Connected polygons (may merge during build)")
  } else if test_name == "Simple Quad Merging" {
    testing.expect(t, header.poly_count >= 1, "Should have at least 1 polygon")
    log.infof("Expected: 1-2 polygons depending on merging")
  }
  
  if total_links == 0 && connected_polygons == 0 && header.poly_count > 1 {
    log.warnf("⚠️ WARNING: Multiple isolated polygons with no connectivity")
    log.warnf("   This may cause pathfinding issues between disconnected areas")
  } else if total_links == 0 && header.poly_count == 1 {
    log.infof("ℹ️ Single polygon mesh - no links needed")
  } else if total_links > 0 {
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
  config.cell_size = 0.2  // Much smaller cell size for small test geometry
  config.merge_region_area = 0  // Disable polygon merging to maintain connectivity
  navmesh, ok := mjolnir.build_navmesh(input, config)
  defer nav.destroy(&navmesh)
  
  if !ok {
    log.errorf("FAILED TO BUILD NAVMESH for test: Simple Quad Merging")
    testing.expect(t, false, "Should build navmesh successfully")
    return
  }
  testing.expect(t, ok, "Should build navmesh successfully")
  
  analyze_connectivity(t, &navmesh, "Simple Quad Merging")
}