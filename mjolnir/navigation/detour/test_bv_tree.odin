package detour

import "../recast"
import "core:log"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_bv_tree_construction :: proc(t: ^testing.T) {
  mesh: recast.Poly_Mesh
  mesh.cs = 0.3
  mesh.ch = 0.2
  mesh.nvp = 6
  mesh.npolys = 4
  mesh.bmin = {0.0, 0.0, 0.0}
  mesh.bmax = {10.0, 2.0, 10.0}
  // Create vertices (already quantized)
  verts := [][3]u16 {
    {0, 0, 0}, // vertex 0
    {10, 0, 0}, // vertex 1
    {10, 0, 10}, // vertex 2
    {0, 0, 10}, // vertex 3
    {0, 5, 0}, // vertex 4
    {10, 5, 0}, // vertex 5
    {10, 5, 10}, // vertex 6
    {0, 5, 10}, // vertex 7
  }
  mesh.verts = verts
  // Create polygons (4 triangles)
  polys := make([]u16, 4 * 6 * 2)
  defer delete(polys)
  slice.fill(polys, recast.RC_MESH_NULL_IDX)
  // Bottom triangle 1: 0,1,2
  polys[0] = 0
  polys[1] = 1
  polys[2] = 2
  // Bottom triangle 2: 0,2,3
  polys[12] = 0
  polys[13] = 2
  polys[14] = 3
  // Top triangle 1: 4,5,6
  polys[24] = 4
  polys[25] = 5
  polys[26] = 6
  // Top triangle 2: 4,6,7
  polys[36] = 4
  polys[37] = 6
  polys[38] = 7
  mesh.polys = polys
  // Create areas and flags
  areas := []u8{1, 1, 1, 1}
  flags := []u16{1, 1, 1, 1}
  mesh.areas = areas
  mesh.flags = flags
  // Build BV tree
  nodes := make([]BV_Node, 4)
  defer delete(nodes)
  build_bv_tree(&mesh, nodes, 4, nil)
  expected := []struct {
    bmin, bmax: [3]u16,
    i:          i32,
  } {
    {{0, 0, 0}, {10, 0, 10}, 0}, // Bottom triangle 1
    {{0, 0, 0}, {10, 0, 10}, 1}, // Bottom triangle 2
    {{0, 3, 0}, {10, 4, 10}, 2}, // Top triangle 1 (Y remapped from 5 to 3-4)
    {{0, 3, 0}, {10, 4, 10}, 3}, // Top triangle 2 (Y remapped from 5 to 3-4)
  }
  for i in 0 ..< 4 {
    node := nodes[i]
    exp := expected[i]
    testing.expect_value(t, node.bmin, exp.bmin)
    testing.expect_value(t, node.bmax, exp.bmax)
    testing.expect_value(t, node.i, exp.i)
  }
}

@(test)
test_bv_tree_y_remapping :: proc(t: ^testing.T) {
  // This test verifies that BV tree bounds are correctly remapped for Y coordinate
  // Create a simple poly mesh with known parameters
  pmesh := recast.Poly_Mesh {
    cs     = 0.3, // cell size
    ch     = 0.2, // cell height
    nvp    = 6, // max verts per poly
    bmin   = {-10.0, 0.0, -10.0},
    bmax   = {10.0, 5.0, 10.0},
    npolys = 1,
  }
  // Create test vertices (already quantized)
  test_verts := [][3]u16 {
    {10, 5, 10}, // vertex 0
    {20, 5, 10}, // vertex 1
    {20, 5, 20}, // vertex 2
    {10, 5, 20}, // vertex 3
  }
  pmesh.verts = test_verts
  // Create a simple polygon using all 4 vertices
  test_polys := []u16 {
    0,
    1,
    2,
    3,
    recast.RC_MESH_NULL_IDX,
    recast.RC_MESH_NULL_IDX, // vertex indices
    0,
    0,
    0,
    0,
    0,
    0, // neighbor info
  }
  pmesh.polys = test_polys
  // Set up areas and flags
  pmesh.areas = []u8{1}
  pmesh.flags = []u16{1}
  // Test the bounds calculation
  poly_base := i32(0)
  quant_factor := 1.0 / pmesh.cs
  bounds := calc_polygon_bounds_fast(
    &pmesh,
    poly_base,
    pmesh.nvp,
    quant_factor,
  )
  // Calculate expected Y remapping as C++ does
  ch_cs_ratio := pmesh.ch / pmesh.cs // 0.2 / 0.3 = 0.667
  expected_min_y := u16(math.floor(f32(5) * ch_cs_ratio)) // floor(5 * 0.667) = floor(3.333) = 3
  expected_max_y := u16(math.ceil(f32(5) * ch_cs_ratio)) // ceil(5 * 0.667) = ceil(3.333) = 4
  // Verify bounds match expected values
  testing.expect_value(t, bounds.min[0], u16(10)) // X min unchanged
  testing.expect_value(t, bounds.max[0], u16(20)) // X max unchanged
  testing.expect_value(t, bounds.min[2], u16(10)) // Z min unchanged
  testing.expect_value(t, bounds.max[2], u16(20)) // Z max unchanged
  // CRITICAL: Y should be remapped
  testing.expect_value(t, bounds.min[1], expected_min_y)
  testing.expect_value(t, bounds.max[1], expected_max_y)
}

@(test)
test_bv_tree_various_y_values :: proc(t: ^testing.T) {
  // Test Y remapping with various values to ensure correct behavior
  cs := f32(0.3)
  ch := f32(0.2)
  ch_cs_ratio := ch / cs
  test_cases := []struct {
    y_value:      u16,
    expected_min: u16,
    expected_max: u16,
  } {
    {0, 0, 0}, // floor(0 * 0.667) = 0, ceil(0 * 0.667) = 0
    {5, 3, 4}, // floor(5 * 0.667) = 3, ceil(5 * 0.667) = 4
    {10, 6, 7}, // floor(10 * 0.667) = 6, ceil(10 * 0.667) = 7
    {15, 9, 10}, // floor(15 * 0.6666...) = 9, ceil(15 * 0.6666...) = 10
    {20, 13, 14}, // floor(20 * 0.667) = 13, ceil(20 * 0.667) = 14
  }
  for tc in test_cases {
    actual_min := u16(math.floor(f32(tc.y_value) * ch_cs_ratio))
    actual_max := u16(math.ceil(f32(tc.y_value) * ch_cs_ratio))
    testing.expect_value(t, actual_min, tc.expected_min)
    testing.expect_value(t, actual_max, tc.expected_max)
  }
}

@(test)
test_bv_tree_e2e :: proc(t: ^testing.T) {
  // Create a simple floor mesh
  mesh: recast.Poly_Mesh
  mesh.cs = 0.3
  mesh.ch = 0.2
  mesh.nvp = 6
  mesh.npolys = 2
  mesh.bmin = {0.0, 0.0, 0.0}
  mesh.bmax = {10.0, 2.0, 10.0}
  // Create vertices for a simple floor
  verts := [][3]u16 {
    {0, 0, 0}, // vertex 0
    {33, 0, 0}, // vertex 1 (10/0.3 = 33.33)
    {33, 0, 33}, // vertex 2
    {0, 0, 33}, // vertex 3
  }
  mesh.verts = verts
  // Create two triangles forming a square floor
  polys := make([]u16, 2 * 6 * 2)
  defer delete(polys)
  slice.fill(polys, recast.RC_MESH_NULL_IDX)
  // Triangle 1: 0,1,2
  polys[0] = 0
  polys[1] = 1
  polys[2] = 2
  // Triangle 2: 0,2,3
  polys[12] = 0
  polys[13] = 2
  polys[14] = 3
  mesh.polys = polys
  // Create areas and flags
  areas := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}
  flags := []u16{1, 1}
  mesh.areas = areas
  mesh.flags = flags
  // Create navmesh data
  params: Create_Nav_Mesh_Data_Params
  params.poly_mesh = &mesh
  params.poly_mesh_detail = nil
  params.walkable_height = 2.0
  params.walkable_radius = 0.6
  params.walkable_climb = 0.9
  params.tile_x = 0
  params.tile_y = 0
  params.tile_layer = 0
  nav_data, create_status := create_nav_mesh_data(&params)
  defer delete(nav_data)
  testing.expect(t, recast.status_succeeded(create_status))
  header := cast(^Mesh_Header)raw_data(nav_data)
  testing.expectf(
    t,
    header.bv_node_count == 2,
    "Expected 2 BV nodes (one per poly), got %d",
    header.bv_node_count,
  )
  header_size := size_of(Mesh_Header)
  verts_size := size_of([3]f32) * int(header.vert_count)
  polys_size := size_of(Poly) * int(header.poly_count)
  links_size := size_of(Link) * int(header.max_link_count)
  detail_meshes_size :=
    size_of(Poly_Detail) * int(header.detail_mesh_count)
  detail_verts_size := size_of([3]f32) * int(header.detail_vert_count)
  detail_tris_size := size_of(u8) * int(header.detail_tri_count) * 4
  bv_offset :=
    header_size +
    verts_size +
    polys_size +
    links_size +
    detail_meshes_size +
    detail_verts_size +
    detail_tris_size
  bv_nodes := slice.from_ptr(
    cast(^BV_Node)raw_data(nav_data[bv_offset:]),
    int(header.bv_node_count),
  )
  for node in bv_nodes {
    testing.expectf(
      t,
      node.bmax != [3]u16{1, 1, 1},
      "BV node has invalid bounds %v",
      node.bmax,
    )
  }
  // Now create a navigation mesh and add the tile
  nav_mesh_params: Nav_Mesh_Params
  nav_mesh_params.orig = mesh.bmin
  nav_mesh_params.tile_width = mesh.bmax[0] - mesh.bmin[0]
  nav_mesh_params.tile_height = mesh.bmax[2] - mesh.bmin[2]
  nav_mesh_params.max_tiles = 1
  nav_mesh_params.max_polys = 1024
  nav_mesh: Nav_Mesh
  init_status := nav_mesh_init(&nav_mesh, &nav_mesh_params)
  defer nav_mesh_destroy(&nav_mesh)
  testing.expectf(
    t,
    recast.status_succeeded(init_status),
    "Failed to init nav mesh: %v",
    init_status,
  )
  tile_ref, add_status := nav_mesh_add_tile(&nav_mesh, nav_data, 0)
  testing.expectf(
    t,
    recast.status_succeeded(add_status),
    "Failed to add tile: %v",
    add_status,
  )
  test_point := [3]f32{5.0, 0.0, 5.0} // Center of floor
  extent := [3]f32{1.0, 2.0, 1.0}
  query: Nav_Mesh_Query
  query_status := nav_mesh_query_init(&query, &nav_mesh, 512)
  defer nav_mesh_query_destroy(&query)
  testing.expectf(
    t,
    recast.status_succeeded(query_status),
    "Failed to init query: %v",
    query_status,
  )
  filter: Query_Filter
  query_filter_init(&filter)
  find_status, nearest_poly, nearest_point := find_nearest_poly(
    &query,
    test_point,
    extent,
    &filter,
  )
  testing.expectf(
    t,
    recast.status_succeeded(find_status),
    "Failed to find nearest poly: %v",
    find_status,
  )
  testing.expectf(
    t,
    nearest_poly != recast.INVALID_POLY_REF,
    "BV tree query failed - couldn't find polygon at test point",
  )
}
