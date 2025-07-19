package tests

import "../mjolnir"
import "../mjolnir/navigation"
import "core:log"
import "core:math/linalg"
import "core:testing"
import "core:time"

// Test navigation mesh with obstacle detection
@(test)
test_navigation_obstacle_detection :: proc(t: ^testing.T) {
  // Simple test with ground and one obstacle
  vertices := [][3]f32{
    // Ground vertices
    {-5, 0, -5},
    { 5, 0, -5},
    { 5, 0,  5},
    {-5, 0,  5},
    // Obstacle vertices (box at center)
    {-1, 0, -1},  // bottom
    { 1, 0, -1},
    { 1, 0,  1},
    {-1, 0,  1},
    {-1, 1, -1},  // top
    { 1, 1, -1},
    { 1, 1,  1},
    {-1, 1,  1},
  }
  
  indices := []u32{
    // Ground triangles
    0, 1, 2,
    0, 2, 3,
    // Obstacle faces
    4, 5, 6,  4, 6, 7,    // bottom
    8, 10, 9, 8, 11, 10,  // top
    4, 5, 9,  4, 9, 8,    // front
    5, 6, 10, 5, 10, 9,   // right
    6, 7, 11, 6, 11, 10,  // back
    7, 4, 8,  7, 8, 11,   // left
  }
  
  areas := []u8{
    navigation.WALKABLE_AREA, navigation.WALKABLE_AREA,  // ground
    navigation.NULL_AREA, navigation.NULL_AREA,          // obstacle bottom
    navigation.NULL_AREA, navigation.NULL_AREA,          // obstacle top
    navigation.NULL_AREA, navigation.NULL_AREA,          // obstacle front
    navigation.NULL_AREA, navigation.NULL_AREA,          // obstacle right
    navigation.NULL_AREA, navigation.NULL_AREA,          // obstacle back
    navigation.NULL_AREA, navigation.NULL_AREA,          // obstacle left
  }
  
  config := navigation.DEFAULT_CONFIG
  config.cs = 0.3
  config.ch = 0.2
  
  builder := navigation.builder_init(config)
  input := navigation.Input{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }
  
  navmesh, ok := navigation.build(&builder, &input)
  testing.expect(t, ok, "Navigation mesh should build")
  
  if ok {
    defer navigation.destroy(&navmesh)
    
    // Check that the navmesh has fewer polygons than a simple quad
    // due to the obstacle creating a hole
    tile := &navmesh.tiles[0]
    if tile.header != nil {
      log.infof("Test: Created navmesh with %d polygons", tile.header.poly_count)
      
      // With an obstacle, we should have more than 2 polygons
      // (ground split around obstacle)
      testing.expect(t, tile.header.poly_count > 2, 
        "NavMesh should have multiple polygons due to obstacle")
    }
    
    // Test path around obstacle
    query := navigation.query_init(&navmesh)
    defer navigation.query_deinit(&query)
    
    start := [3]f32{-3, 0, 0}
    end := [3]f32{3, 0, 0}
    path, found := navigation.find_path(&query, start, end)
    defer delete(path)
    
    testing.expect(t, found, "Path should be found")
    
    if found && len(path) > 2 {
      // Path should go around the obstacle, not straight through
      for i in 1..<len(path)-1 {
        p := path[i]
        // Check if any waypoint is inside the obstacle
        inside_obstacle := p.x >= -1 && p.x <= 1 && p.z >= -1 && p.z <= 1
        testing.expect(t, !inside_obstacle, 
          "Path waypoint should not be inside obstacle")
      }
    }
  }
}

// Test basic navigation mesh building from simple geometry
@(test)
test_detour_navmesh_build :: proc(t: ^testing.T) {
  // Simple quad geometry
  vertices := [][3]f32{{0, 0, 0}, {10, 0, 0}, {10, 0, 10}, {0, 0, 10}}
  indices := []u32{0, 1, 2, 0, 2, 3}
  areas := []u8{u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA)}

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh build should succeed")
  defer navigation.destroy(&navmesh)

  testing.expect(t, navmesh.max_tiles > 0, "NavMesh should have tiles")
  testing.expect(t, len(navmesh.tiles) > 0, "NavMesh should have tile array")
  
  // Check first tile
  tile := &navmesh.tiles[0]
  if tile.header != nil {
    testing.expect(t, tile.header.poly_count > 0, "Tile should have polygons")
    testing.expect(t, tile.header.vert_count > 0, "Tile should have vertices")
    testing.expect(t, len(tile.polys) > 0, "Tile should have polygon array")
    testing.expect(t, len(tile.verts) > 0, "Tile should have vertex array")
  }
}

// Test pathfinding with the new Detour-style system
@(test)
test_detour_pathfinding :: proc(t: ^testing.T) {
  // Create a simple walkable area
  vertices := [][3]f32{{0, 0, 0}, {6, 0, 0}, {6, 0, 6}, {0, 0, 6}}
  indices := []u32{0, 1, 2, 0, 2, 3}
  areas := []u8{u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA)}

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.5 // Smaller cells for better resolution
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh build should succeed")
  defer navigation.destroy(&navmesh)

  query := navigation.query_init(&navmesh)
  defer navigation.query_deinit(&query)

  start := [3]f32{1, 0, 1}
  end := [3]f32{5, 0, 5}

  path, path_found := navigation.find_path(&query, start, end)
  testing.expect(t, path_found, "Should find a path")

  if path_found {
    defer delete(path)
    testing.expect(t, len(path) >= 1, "Path should have at least one waypoint")
    
    // Verify path points are within reasonable bounds
    for point in path {
      testing.expect(t, point.x >= -1 && point.x <= 7, "Path X should be in bounds")
      testing.expect(t, point.z >= -1 && point.z <= 7, "Path Z should be in bounds")
    }
  }
}

// Test find_nearest_poly_ref function
@(test)
test_find_nearest_poly_ref :: proc(t: ^testing.T) {
  vertices := [][3]f32{{0, 0, 0}, {4, 0, 0}, {4, 0, 4}, {0, 0, 4}}
  indices := []u32{0, 1, 2, 0, 2, 3}
  areas := []u8{u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA)}

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh build should succeed")
  defer navigation.destroy(&navmesh)

  // Test point inside mesh
  center_pos := [3]f32{2, 0, 2}
  poly_ref := navigation.find_nearest_poly_ref(&navmesh, center_pos, [3]f32{1, 1, 1})
  testing.expect(t, poly_ref != 0, "Should find polygon for point inside mesh")

  // Test point outside mesh
  outside_pos := [3]f32{10, 0, 10}
  poly_ref_outside := navigation.find_nearest_poly_ref(&navmesh, outside_pos, [3]f32{1, 1, 1})
  testing.expect(t, poly_ref_outside == 0, "Should not find polygon for point outside mesh")
}

// Test polygon area assignment
@(test)
test_polygon_areas :: proc(t: ^testing.T) {
  vertices := [][3]f32{
    {0, 0, 0}, {2, 0, 0}, {2, 0, 2}, {0, 0, 2}, // Walkable area
    {2, 0, 0}, {4, 0, 0}, {4, 0, 2}, {2, 0, 2}, // Water area
  }
  indices := []u32{
    0, 1, 2, 0, 2, 3, // Walkable triangles
    4, 5, 6, 4, 6, 7, // Water triangles
  }
  areas := []u8{
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
    u8(navigation.AREA_WATER), u8(navigation.AREA_WATER),
  }

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Multi-area navigation mesh should build")
  defer navigation.destroy(&navmesh)

  // Verify areas are correctly assigned
  walkable_found := false
  water_found := false

  for &tile in navmesh.tiles {
    if tile.header == nil do continue
    for i in 0..<tile.header.poly_count {
      poly := &tile.polys[i]
      area := navigation.get_poly_area(poly)
      if area == u8(navigation.WALKABLE_AREA) {
        walkable_found = true
      } else if area == u8(navigation.AREA_WATER) {
        water_found = true
      }
    }
  }

  testing.expect(t, walkable_found, "Should have walkable polygons")
  testing.expect(t, water_found, "Should have water polygons")
}

// Test navmesh bounds calculation
@(test)
test_navmesh_bounds :: proc(t: ^testing.T) {
  vertices := [][3]f32{{-5, -1, -5}, {5, 1, 5}}
  indices := []u32{0, 1, 0} // Degenerate triangle, but tests bounds
  areas := []u8{u8(navigation.WALKABLE_AREA)}

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh should build with bounds test")
  defer navigation.destroy(&navmesh)

  // Check that tile header contains correct bounds
  tile := &navmesh.tiles[0]
  if tile.header != nil {
    bmin := tile.header.bmin
    bmax := tile.header.bmax
    
    testing.expect(t, bmin.x <= -5, "Min X should be correct")
    testing.expect(t, bmin.y <= -1, "Min Y should be correct") 
    testing.expect(t, bmin.z <= -5, "Min Z should be correct")
    testing.expect(t, bmax.x >= 5, "Max X should be correct")
    testing.expect(t, bmax.y >= 1, "Max Y should be correct")
    testing.expect(t, bmax.z >= 5, "Max Z should be correct")
  }
}

// Test error handling with invalid input
@(test)
test_invalid_input_handling :: proc(t: ^testing.T) {
  config := mjolnir.default_navmesh_config()
  
  // Test 1: Empty input
  empty_input := navigation.NavMeshInput{
    vertices = {},
    indices = {},
    areas = {},
  }

  navmesh, ok := mjolnir.build_navmesh(empty_input, config)
  testing.expect(t, !ok, "Should fail with empty input")

  // Test 2: Mismatched indices and areas - partial area specification should fail with strict validation
  vertices := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}}
  indices := []u32{0, 1, 2, 0, 2, 3}  // 2 triangles
  areas := []u8{u8(navigation.WALKABLE_AREA)} // Only 1 area for 2 triangles - this should fail

  mismatched_input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  navmesh2, ok2 := mjolnir.build_navmesh(mismatched_input, config)
  testing.expect(t, !ok2, "Should reject mismatched area count (strict validation)")
}

// Test pathfinding with obstacles
@(test)
test_pathfinding_with_obstacles :: proc(t: ^testing.T) {
  // Create L-shaped walkable area (obstacle in the middle)
  vertices := [][3]f32{
    // Bottom part of L
    {0, 0, 0}, {6, 0, 0}, {6, 0, 2}, {0, 0, 2},
    // Top part of L
    {0, 0, 2}, {2, 0, 2}, {2, 0, 6}, {0, 0, 6},
  }
  indices := []u32{
    0, 1, 2, 0, 2, 3, // Bottom rectangles
    4, 5, 6, 4, 6, 7, // Top rectangles
  }
  areas := []u8{
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
  }

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.4 // Good resolution for this test
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "L-shaped navigation mesh should build")
  defer navigation.destroy(&navmesh)

  query := navigation.query_init(&navmesh)
  defer navigation.query_deinit(&query)

  // Path that should go around the obstacle
  start := [3]f32{5, 0, 1}  // Bottom right
  end := [3]f32{1, 0, 5}    // Top left

  path, path_found := navigation.find_path(&query, start, end)
  testing.expect(t, path_found, "Should find path around obstacle")

  if path_found {
    defer delete(path)
    testing.expect(t, len(path) >= 1, "Path should have waypoints")
    
    // Path should not go through the blocked area (middle-right region)
    for point in path {
      blocked_area := point.x > 2 && point.x < 6 && point.z > 2 && point.z < 6
      testing.expect(t, !blocked_area, "Path should not go through blocked area")
    }
  }
}

// Test performance with larger meshes
@(test)
test_performance_large_mesh :: proc(t: ^testing.T) {
  // Create a grid of triangles
  grid_size := 20
  vertices := make([][3]f32, (grid_size + 1) * (grid_size + 1))
  defer delete(vertices)

  // Generate grid vertices
  for y in 0..=grid_size {
    for x in 0..=grid_size {
      idx := y * (grid_size + 1) + x
      vertices[idx] = {f32(x), 0, f32(y)}
    }
  }

  // Generate triangle indices
  indices := make([]u32, grid_size * grid_size * 6) // 2 triangles per cell
  defer delete(indices)
  
  triangle_idx := 0
  for y in 0..<grid_size {
    for x in 0..<grid_size {
      v0 := u32(y * (grid_size + 1) + x)
      v1 := u32(y * (grid_size + 1) + x + 1)
      v2 := u32((y + 1) * (grid_size + 1) + x)
      v3 := u32((y + 1) * (grid_size + 1) + x + 1)
      
      // First triangle
      indices[triangle_idx*6 + 0] = v0
      indices[triangle_idx*6 + 1] = v1
      indices[triangle_idx*6 + 2] = v2
      // Second triangle
      indices[triangle_idx*6 + 3] = v1
      indices[triangle_idx*6 + 4] = v3
      indices[triangle_idx*6 + 5] = v2
      triangle_idx += 1
    }
  }

  // All triangles are walkable
  areas := make([]u8, len(indices) / 3)
  defer delete(areas)
  for &area in areas {
    area = u8(navigation.WALKABLE_AREA)
  }

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.8 // Reasonable cell size for performance

  start_time := time.now()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  build_time := time.since(start_time)
  
  testing.expect(t, ok, "Large navigation mesh should build successfully")
  testing.expect(t, time.duration_milliseconds(build_time) < 5000, "Build should complete in reasonable time")
  defer navigation.destroy(&navmesh)

  // Test pathfinding performance
  query := navigation.query_init(&navmesh)
  defer navigation.query_deinit(&query)

  start_pos := [3]f32{1, 0, 1}
  end_pos := [3]f32{f32(grid_size-1), 0, f32(grid_size-1)}

  path_start_time := time.now()
  path, path_found := navigation.find_path(&query, start_pos, end_pos)
  path_time := time.since(path_start_time)

  testing.expect(t, path_found, "Should find path in large mesh")
  testing.expect(t, time.duration_milliseconds(path_time) < 100, "Pathfinding should be fast")

  if path_found {
    defer delete(path)
    testing.expect(t, len(path) >= 1, "Path should have waypoints")
  }

  log.infof("Large mesh test: %d triangles, build: %v, pathfinding: %v", 
    len(indices)/3, build_time, path_time)
}

// Test configuration parameter effects
@(test)
test_configuration_parameters :: proc(t: ^testing.T) {
  vertices := [][3]f32{{0, 0, 0}, {10, 0, 0}, {10, 0, 10}, {0, 0, 10}}
  indices := []u32{0, 1, 2, 0, 2, 3}
  areas := []u8{u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA)}

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  // Test with different cell sizes
  config_small := mjolnir.default_navmesh_config()
  config_small.cell_size = 0.1 // Very small cells

  config_large := mjolnir.default_navmesh_config()
  config_large.cell_size = 2.0 // Large cells

  navmesh_small, ok_small := mjolnir.build_navmesh(input, config_small)
  testing.expect(t, ok_small, "Small cell navmesh should build")
  defer navigation.destroy(&navmesh_small)

  navmesh_large, ok_large := mjolnir.build_navmesh(input, config_large)
  testing.expect(t, ok_large, "Large cell navmesh should build")
  defer navigation.destroy(&navmesh_large)

  // Small cells should generally produce more polygons
  small_poly_count := 0
  large_poly_count := 0

  for &tile in navmesh_small.tiles {
    if tile.header != nil {
      small_poly_count += int(tile.header.poly_count)
    }
  }

  for &tile in navmesh_large.tiles {
    if tile.header != nil {
      large_poly_count += int(tile.header.poly_count)
    }
  }

  testing.expect(t, small_poly_count > 0, "Small cell mesh should have polygons")
  testing.expect(t, large_poly_count > 0, "Large cell mesh should have polygons")

  log.infof("Cell size effect: small(%.1f) = %d polys, large(%.1f) = %d polys",
    config_small.cell_size, small_poly_count, config_large.cell_size, large_poly_count)
}

// Test scene extraction from mjolnir scene system
@(test)
test_scene_navmesh_extraction :: proc(t: ^testing.T) {
  // This test would need a mock scene, but we can test the interface
  config := mjolnir.default_navmesh_config()
  
  // Test that the default config has reasonable values
  testing.expect(t, config.cell_size > 0, "Cell size should be positive")
  testing.expect(t, config.cell_height > 0, "Cell height should be positive")
  testing.expect(t, config.agent_height > 0, "Agent height should be positive")
  testing.expect(t, config.agent_radius > 0, "Agent radius should be positive")
  testing.expect(t, config.max_verts_per_poly >= 3, "Max verts per poly should be at least 3")

  // Test config conversion to internal format
  nav_config := navigation.Config{
    cs = config.cell_size,
    ch = config.cell_height,
    walkable_slope_angle = config.agent_max_slope,
    walkable_height = i32(config.agent_height / config.cell_height),
    walkable_climb = i32(config.agent_max_climb / config.cell_height),
    walkable_radius = i32(config.agent_radius / config.cell_size),
    max_verts_per_poly = config.max_verts_per_poly,
  }

  testing.expect(t, nav_config.cs == config.cell_size, "Cell size conversion should match")
  testing.expect(t, nav_config.walkable_height > 0, "Walkable height should convert properly")
  testing.expect(t, nav_config.walkable_radius > 0, "Walkable radius should convert properly")
}

// Test mathematical utility functions (inspired by Recast tests)
@(test)
test_navigation_math_utilities :: proc(t: ^testing.T) {
  // Test bounds calculation
  vertices := [][3]f32{{-1, -2, -3}, {4, 5, 6}, {0, 1, 0}}
  
  bmin := vertices[0]
  bmax := vertices[0]
  for vertex in vertices[1:] {
    bmin = linalg.min(bmin, vertex)
    bmax = linalg.max(bmax, vertex)
  }
  
  testing.expect(t, bmin.x == -1, "Min X should be correct")
  testing.expect(t, bmin.y == -2, "Min Y should be correct")
  testing.expect(t, bmin.z == -3, "Min Z should be correct")
  testing.expect(t, bmax.x == 4, "Max X should be correct")
  testing.expect(t, bmax.y == 5, "Max Y should be correct")
  testing.expect(t, bmax.z == 6, "Max Z should be correct")

  // Test triangle overlap with box
  tri_a := [2]f32{0, 0}
  tri_b := [2]f32{2, 0}
  tri_c := [2]f32{1, 2}
  
  box_min_overlap := [2]f32{0.5, 0.5}
  box_max_overlap := [2]f32{1.5, 1.5}
  
  box_min_no_overlap := [2]f32{3, 3}
  box_max_no_overlap := [2]f32{4, 4}
  
  overlaps := navigation.triangle_overlaps_box_2d(tri_a, tri_b, tri_c, box_min_overlap, box_max_overlap)
  no_overlaps := navigation.triangle_overlaps_box_2d(tri_a, tri_b, tri_c, box_min_no_overlap, box_max_no_overlap)
  
  testing.expect(t, overlaps, "Triangle should overlap box")
  testing.expect(t, !no_overlaps, "Triangle should not overlap distant box")

  // Test point in triangle
  point_inside := [2]f32{1, 0.5}
  point_outside := [2]f32{3, 3}
  
  inside := navigation.point_in_triangle_2d(point_inside, tri_a, tri_b, tri_c)
  outside := navigation.point_in_triangle_2d(point_outside, tri_a, tri_b, tri_c)
  
  testing.expect(t, inside, "Point should be inside triangle")
  testing.expect(t, !outside, "Point should be outside triangle")
}

// Test polygon encoding/decoding (Detour-style IDs)
@(test)
test_polygon_reference_system :: proc(t: ^testing.T) {
  vertices := [][3]f32{{0, 0, 0}, {2, 0, 0}, {2, 0, 2}, {0, 0, 2}}
  indices := []u32{0, 1, 2, 0, 2, 3}
  areas := []u8{u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA)}

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh build should succeed")
  defer navigation.destroy(&navmesh)

  // Test that polygon references are encoded properly
  center_pos := [3]f32{1, 0, 1}
  poly_ref := navigation.find_nearest_poly_ref(&navmesh, center_pos, [3]f32{0.5, 0.5, 0.5})
  testing.expect(t, poly_ref != 0, "Should find a valid polygon reference")

  // Test decoding polygon reference components
  salt := navigation.decode_poly_id_salt(poly_ref)
  tile_idx := navigation.decode_poly_id_tile(poly_ref)
  poly_idx := navigation.decode_poly_id_poly(poly_ref)
  testing.expect(t, tile_idx < u32(navmesh.max_tiles), "Tile index should be valid")
  testing.expect(t, poly_idx < u32(navmesh.tiles[tile_idx].header.poly_count), "Polygon index should be valid")

  // Test encoding/decoding round trip
  re_encoded := navigation.encode_poly_id(salt, tile_idx, poly_idx)
  testing.expect(t, re_encoded == poly_ref, "Encoding/decoding should be reversible")
}

// Test navmesh serialization and data integrity
@(test)
test_navmesh_data_integrity :: proc(t: ^testing.T) {
  vertices := [][3]f32{{0, 0, 0}, {3, 0, 0}, {3, 0, 3}, {0, 0, 3}}
  indices := []u32{0, 1, 2, 0, 2, 3}
  areas := []u8{u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA)}

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Navigation mesh build should succeed")
  defer navigation.destroy(&navmesh)

  // Verify navmesh structure integrity
  testing.expect(t, navmesh.max_tiles > 0, "NavMesh should have valid maxTiles")
  testing.expect(t, len(navmesh.tiles) == int(navmesh.max_tiles), "Tiles array should match maxTiles")

  // Check first tile integrity
  tile := &navmesh.tiles[0]
  if tile.header != nil {
    testing.expect(t, tile.header.magic == navigation.NAVMESH_MAGIC, "Tile should have correct magic number")
    testing.expect(t, tile.header.version == navigation.NAVMESH_VERSION, "Tile should have correct version")
    testing.expect(t, tile.header.poly_count > 0, "Tile should have polygons")
    testing.expect(t, tile.header.vert_count > 0, "Tile should have vertices")
    
    // Verify vertex data integrity
    testing.expect(t, len(tile.verts) == int(tile.header.vert_count * 3), "Vertex array should match header count")
    
    // Verify polygon data integrity
    testing.expect(t, len(tile.polys) == int(tile.header.poly_count), "Polygon array should match header count")
    
    // Check that all polygons have valid vertex indices
    for i in 0..<tile.header.poly_count {
      poly := &tile.polys[i]
      testing.expect(t, poly.vert_count >= 3, "Polygon should have at least 3 vertices")
      testing.expect(t, poly.vert_count <= 6, "Polygon should not exceed max vertices (6 for DT_VERTS_PER_POLYGON)")
      
      for j in 0..<poly.vert_count {
        vert_idx := poly.verts[j]
        testing.expect(t, vert_idx < u16(tile.header.vert_count), "Vertex index should be valid")
      }
    }
  }
}

// Test walkable slope detection (inspired by Recast walkable triangle tests)
@(test)
test_walkable_slope_detection :: proc(t: ^testing.T) {
  // Test flat ground (should be walkable)
  flat_vertices := [][3]f32{{0, 0, 0}, {2, 0, 0}, {2, 0, 2}, {0, 0, 2}}
  flat_indices := []u32{0, 1, 2, 0, 2, 3}
  flat_areas := []u8{u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA)}

  flat_input := navigation.NavMeshInput{
    vertices = flat_vertices,
    indices = flat_indices,
    areas = flat_areas,
  }

  config := mjolnir.default_navmesh_config()
  config.agent_max_slope = 45.0 // 45 degree max slope
  
  flat_navmesh, flat_ok := mjolnir.build_navmesh(flat_input, config)
  testing.expect(t, flat_ok, "Flat mesh should build successfully")
  defer navigation.destroy(&flat_navmesh)

  // Verify flat mesh has walkable polygons
  flat_walkable_count := 0
  for &tile in flat_navmesh.tiles {
    if tile.header == nil do continue
    for i in 0..<tile.header.poly_count {
      poly := &tile.polys[i]
      area := navigation.get_poly_area(poly)
      if area == u8(navigation.WALKABLE_AREA) {
        flat_walkable_count += 1
      }
    }
  }
  testing.expect(t, flat_walkable_count > 0, "Flat mesh should have walkable polygons")

  // Test steep slope (should be filtered out with strict slope limits)
  steep_vertices := [][3]f32{{0, 0, 0}, {1, 2, 0}, {0, 2, 1}} // Very steep triangle
  steep_indices := []u32{0, 1, 2}
  steep_areas := []u8{u8(navigation.WALKABLE_AREA)}

  steep_input := navigation.NavMeshInput{
    vertices = steep_vertices,
    indices = steep_indices,
    areas = steep_areas,
  }

  strict_config := mjolnir.default_navmesh_config()
  strict_config.agent_max_slope = 5.0 // Very strict slope limit
  
  steep_navmesh, steep_ok := mjolnir.build_navmesh(steep_input, strict_config)
  testing.expect(t, steep_ok, "Steep mesh should build (but may have no walkable areas)")
  defer navigation.destroy(&steep_navmesh)

  log.infof("Slope test: flat mesh has %d walkable polygons", flat_walkable_count)
}

// Test query filter system
@(test)
test_query_filter_system :: proc(t: ^testing.T) {
  // Create a mesh with multiple area types
  vertices := [][3]f32{
    {0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}, // Walkable area
    {1, 0, 0}, {2, 0, 0}, {2, 0, 1}, {1, 0, 1}, // Water area
  }
  indices := []u32{
    0, 1, 2, 0, 2, 3, // Walkable triangles
    4, 5, 6, 4, 6, 7, // Water triangles
  }
  areas := []u8{
    u8(navigation.WALKABLE_AREA), u8(navigation.WALKABLE_AREA),
    u8(navigation.AREA_WATER), u8(navigation.AREA_WATER),
  }

  input := navigation.NavMeshInput{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  config := mjolnir.default_navmesh_config()
  navmesh, ok := mjolnir.build_navmesh(input, config)
  testing.expect(t, ok, "Multi-area navmesh should build")
  defer navigation.destroy(&navmesh)

  // Test default filter creation
  default_filter := navigation.query_filter_default()
  
  // Test that area costs are configured (check internal structure)
  testing.expect(t, len(default_filter.area_cost) > 0, "Filter should have area cost array")
  
  // Test that default costs exist for common areas
  walkable_cost := default_filter.area_cost[u8(navigation.WALKABLE_AREA)]
  water_cost := default_filter.area_cost[u8(navigation.AREA_WATER)]
  
  testing.expect(t, walkable_cost > 0, "Walkable area should have positive cost")
  testing.expect(t, water_cost > 0, "Water area should have positive cost")
  testing.expect(t, water_cost > walkable_cost, "Water should be more expensive than walkable")
}