package navigation

import "../geometry"
import "core:log"
import "core:math/linalg"
import "detour"
import "recast"

NavObstacleType :: enum {
  Static,
  Dynamic,
}

NavMesh :: struct {
  detour_mesh: detour.Nav_Mesh,
  bounds:      geometry.Aabb,
  cell_size:   f32,
  tile_size:   i32,
  is_tiled:    bool,
  area_costs:  [64]f32,
}

NavContext :: struct {
  nav_mesh_query: detour.Nav_Mesh_Query,
  query_filter:   detour.Query_Filter,
}

NavigationGeometry :: struct {
  vertices:   [][3]f32,
  indices:    []i32,
  area_types: []u8,
}

TileCoord :: struct {
  x, y: i32,
}
NavigationSystem :: struct {
  nav_mesh:       NavMesh,
  nav_mesh_query: detour.Nav_Mesh_Query,
  query_filter:   detour.Query_Filter,
}

init :: proc(sys: ^NavigationSystem, max_nodes: i32 = 2048) -> bool {
  init_status := detour.nav_mesh_query_init(
    &sys.nav_mesh_query,
    &sys.nav_mesh.detour_mesh,
    max_nodes,
  )
  if !recast.status_succeeded(init_status) {
    log.errorf("Failed to initialize navigation mesh query: %v", init_status)
    return false
  }
  detour.query_filter_init(&sys.query_filter)
  log.info("Created navigation context")
  return true
}

shutdown :: proc(sys: ^NavigationSystem) {
  detour.nav_mesh_query_destroy(&sys.nav_mesh_query)
  detour.nav_mesh_destroy(&sys.nav_mesh.detour_mesh)
}

build_navmesh :: proc(
  nav_mesh: ^NavMesh,
  geom: NavigationGeometry,
  config: recast.Config = {},
) -> bool {
  if len(geom.vertices) == 0 || len(geom.indices) == 0 {
    log.error("Cannot build navigation mesh from empty geometry")
    return false
  }
  log.infof(
    "Building navigation mesh from %d vertices, %d indices",
    len(geom.vertices),
    len(geom.indices),
  )
  pmesh, dmesh := recast.build_navmesh(
    geom.vertices[:],
    geom.indices[:],
    geom.area_types[:],
    config,
  ) or_return
  defer {
    recast.free_poly_mesh(pmesh)
    recast.free_poly_mesh_detail(dmesh)
  }
  nav_params := detour.Create_Nav_Mesh_Data_Params {
    poly_mesh          = pmesh,
    poly_mesh_detail   = dmesh,
    walkable_height    = f32(config.walkable_height) * config.ch,
    walkable_radius    = f32(config.walkable_radius) * config.cs,
    walkable_climb     = f32(config.walkable_climb) * config.ch,
    tile_x             = 0,
    tile_y             = 0,
    tile_layer         = 0,
    user_id            = 0,
    off_mesh_con_count = 0,
  }
  nav_data, create_status := detour.create_nav_mesh_data(&nav_params)
  if !recast.status_succeeded(create_status) {
    log.errorf("Failed to create navigation mesh data: %v", create_status)
    return false
  }
  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax[0] - pmesh.bmin[0],
    tile_height = pmesh.bmax[2] - pmesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }
  init_status := detour.nav_mesh_init(&nav_mesh.detour_mesh, &mesh_params)
  if !recast.status_succeeded(init_status) {
    log.errorf("Failed to initialize navigation mesh: %v", init_status)
    return false
  }
  _, add_status := detour.nav_mesh_add_tile(
    &nav_mesh.detour_mesh,
    nav_data,
    recast.DT_TILE_FREE_DATA,
  )
  if !recast.status_succeeded(add_status) {
    log.errorf("Failed to add tile to navigation mesh: %v", add_status)
    detour.nav_mesh_destroy(&nav_mesh.detour_mesh)
    return false
  }
  nav_mesh.bounds = calculate_bounds_from_vertices(geom.vertices[:])
  nav_mesh.cell_size = config.cs
  nav_mesh.tile_size = config.tile_size
  nav_mesh.is_tiled = config.tile_size > 0
  for i in 0 ..< 64 {
    nav_mesh.area_costs[i] = 1.0
  }
  log.info("Successfully built navigation mesh")
  return true
}

calculate_bounds_from_vertices :: proc(vertices: [][3]f32) -> geometry.Aabb {
  if len(vertices) == 0 {
    return {}
  }
  min_pos := vertices[0]
  max_pos := vertices[0]
  for v in vertices[1:] {
    min_pos = linalg.min(min_pos, v)
    max_pos = linalg.max(max_pos, v)
  }
  return geometry.Aabb{min = min_pos, max = max_pos}
}

find_path :: proc(
  sys: ^NavigationSystem,
  start: [3]f32,
  end: [3]f32,
  max_path_length: i32 = 256,
) -> (
  path: [][3]f32,
  ok: bool,
) #optional_ok {
  half_extents := [3]f32{2.0, 4.0, 2.0}
  status, start_ref, start_pos := detour.find_nearest_poly(
    &sys.nav_mesh_query,
    start,
    half_extents,
    &sys.query_filter,
  )
  if !recast.status_succeeded(status) || start_ref == recast.INVALID_POLY_REF {
    log.errorf(
      "Failed to find start polygon for pathfinding at position %v",
      start,
    )
    return nil, false
  }
  status2: recast.Status
  end_ref: recast.Poly_Ref
  end_pos: [3]f32
  status2, end_ref, end_pos = detour.find_nearest_poly(
    &sys.nav_mesh_query,
    end,
    half_extents,
    &sys.query_filter,
  )
  if !recast.status_succeeded(status2) || end_ref == recast.INVALID_POLY_REF {
    log.errorf(
      "Failed to find end polygon for pathfinding at position %v",
      end,
    )
    return nil, false
  }
  poly_path := make([]recast.Poly_Ref, max_path_length, context.temp_allocator)
  path_status, path_count := detour.find_path(
    &sys.nav_mesh_query,
    start_ref,
    end_ref,
    start_pos,
    end_pos,
    &sys.query_filter,
    poly_path[:],
    max_path_length,
  )
  if !recast.status_succeeded(path_status) || path_count == 0 {
    log.errorf(
      "Failed to find path from %v to %v: %v",
      start,
      end,
      path_status,
    )
    return nil, false
  }
  straight_path := make(
    []detour.Straight_Path_Point,
    max_path_length,
    context.temp_allocator,
  )
  straight_status, straight_path_count := detour.find_straight_path(
    &sys.nav_mesh_query,
    start_pos,
    end_pos,
    poly_path[:path_count],
    path_count,
    straight_path[:],
    nil,
    nil,
    max_path_length,
    u32(detour.Straight_Path_Options.All_Crossings),
  )
  if !recast.status_succeeded(straight_status) || straight_path_count == 0 {
    log.errorf("Failed to create straight path: %v", straight_status)
    return nil, false
  }
  result_path := make([][3]f32, straight_path_count)
  for i in 0 ..< straight_path_count {
    result_path[i] = straight_path[i].pos
  }
  log.infof(
    "Found path with %d waypoints from %v to %v",
    straight_path_count,
    start,
    end,
  )
  return result_path, true
}

is_position_walkable :: proc(
  sys: ^NavigationSystem,
  position: [3]f32,
) -> bool {
  half_extents := [3]f32{1.0, 2.0, 1.0}
  status, poly_ref, nearest_pos := detour.find_nearest_poly(
    &sys.nav_mesh_query,
    position,
    half_extents,
    &sys.query_filter,
  )
  return recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF
}

find_nearest_point :: proc(
  sys: ^NavigationSystem,
  position: [3]f32,
  search_extents: [3]f32 = {2.0, 4.0, 2.0},
) -> (
  nearest_pos: [3]f32,
  found: bool,
) {
  status, poly_ref, result_pos := detour.find_nearest_poly(
    &sys.nav_mesh_query,
    position,
    search_extents,
    &sys.query_filter,
  )
  if recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF {
    return result_pos, true
  }
  return {}, false
}

build_geometry :: proc(nav_mesh: ^NavMesh) -> geometry.Geometry {
  vertices := make([dynamic]geometry.Vertex, 0, 4096)
  indices := make([dynamic]u32, 0, 16384)
  defer delete(vertices)
  defer delete(indices)
  for i in 0 ..< nav_mesh.detour_mesh.max_tiles {
    tile := &nav_mesh.detour_mesh.tiles[i]
    if tile.header == nil do continue
    vertex_base := u32(len(vertices))
    for vert_idx in 0 ..< tile.header.vert_count {
      pos := tile.verts[vert_idx]
      append(&vertices, geometry.Vertex{position = pos})
    }
    for poly_idx in 0 ..< tile.header.poly_count {
      poly := &tile.polys[poly_idx]
      vert_count := int(poly.vert_count)
      if vert_count < 3 do continue
      for j in 1 ..< vert_count - 1 {
        append(
          &indices,
          vertex_base + u32(poly.verts[0]),
          vertex_base + u32(poly.verts[j]),
          vertex_base + u32(poly.verts[j + 1]),
        )
      }
    }
  }
  result := geometry.Geometry {
    vertices = make([]geometry.Vertex, len(vertices)),
    indices  = make([]u32, len(indices)),
  }
  copy(result.vertices, vertices[:])
  copy(result.indices, indices[:])
  return result
}

convert_geometry_to_nav :: proc(
  vertices: []geometry.Vertex,
  indices: []u32,
) -> (
  nav_vertices: [][3]f32,
  nav_indices: []i32,
) {
  nav_vertices = make([][3]f32, len(vertices))
  for v, i in vertices {
    nav_vertices[i] = v.position
  }
  nav_indices = make([]i32, len(indices))
  for idx, i in indices {
    nav_indices[i] = i32(idx)
  }
  return
}
