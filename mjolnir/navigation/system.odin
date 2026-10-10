package navigation

import "core:log"
import "detour"
import "recast"

// A built navigation mesh plus the query used for path and point lookups.
// The detour fields are exposed for advanced use (e.g. navigation/crowd).
NavMesh :: struct {
  detour_mesh: detour.Nav_Mesh,
  query:       detour.Nav_Mesh_Query,
  filter:      detour.Query_Filter,
}

NavigationGeometry :: struct {
  vertices:   [][3]f32,
  indices:    []i32,
  area_types: []u8,
}

// Accumulator for building NavigationGeometry from multiple source geoms.
NavGeometryBuilder :: struct {
  vertices:   [dynamic][3]f32,
  indices:    [dynamic]i32,
  area_types: [dynamic]u8,
}

// Append a triangle mesh to a builder. Triangles are walkable unless
// `is_obstacle`. Every position is offset by `offset`.
append_triangles :: proc(
  b: ^NavGeometryBuilder,
  positions: [][3]f32,
  indices: []u32,
  offset: [3]f32 = {0, 0, 0},
  is_obstacle: bool = false,
) {
  base := i32(len(b.vertices))
  for p in positions do append(&b.vertices, p + offset)
  for i in indices do append(&b.indices, base + i32(i))
  area: u8 = u8(recast.RC_NULL_AREA) if is_obstacle else u8(recast.RC_WALKABLE_AREA)
  for _ in 0 ..< len(indices) / 3 do append(&b.area_types, area)
}

// Snapshot the builder's slices into a NavigationGeometry view (no copy).
geometry_view :: proc(b: ^NavGeometryBuilder) -> NavigationGeometry {
  return {vertices = b.vertices[:], indices = b.indices[:], area_types = b.area_types[:]}
}

builder_destroy :: proc(b: ^NavGeometryBuilder) {
  delete(b.vertices)
  delete(b.indices)
  delete(b.area_types)
  b^ = {}
}


// Build the mesh and its query from triangle soup, replacing any previous
// build.
build :: proc(
  nav: ^NavMesh,
  geom: NavigationGeometry,
  config: NavMeshConfig = DEFAULT_NAVMESH_CONFIG,
  max_query_nodes: i32 = 2048,
) -> bool {
  destroy(nav)
  if len(geom.vertices) == 0 || len(geom.indices) == 0 {
    log.error("Cannot build navigation mesh from empty geometry")
    return false
  }
  cfg := config_to_recast(config)
  pmesh, dmesh := recast.build_navmesh(geom.vertices, geom.indices, geom.area_types, cfg) or_return
  defer {
    recast.destroy_poly_mesh(pmesh)
    recast.destroy_poly_mesh_detail(dmesh)
  }
  nav_params := detour.Create_Nav_Mesh_Data_Params {
    poly_mesh        = pmesh,
    poly_mesh_detail = dmesh,
    walkable_height  = f32(cfg.walkable_height) * cfg.ch,
    walkable_radius  = f32(cfg.walkable_radius) * cfg.cs,
    walkable_climb   = f32(cfg.walkable_climb) * cfg.ch,
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
  if status := detour.nav_mesh_init(&nav.detour_mesh, &mesh_params); !recast.status_succeeded(status) {
    log.errorf("Failed to initialize navigation mesh: %v", status)
    return false
  }
  if _, status := detour.nav_mesh_add_tile(&nav.detour_mesh, nav_data, recast.DT_TILE_FREE_DATA); !recast.status_succeeded(status) {
    log.errorf("Failed to add tile to navigation mesh: %v", status)
    destroy(nav)
    return false
  }
  if status := detour.nav_mesh_query_init(&nav.query, &nav.detour_mesh, max_query_nodes); !recast.status_succeeded(status) {
    log.errorf("Failed to initialize navigation mesh query: %v", status)
    destroy(nav)
    return false
  }
  detour.query_filter_init(&nav.filter)
  return true
}

destroy :: proc(nav: ^NavMesh) {
  detour.nav_mesh_query_destroy(&nav.query)
  detour.nav_mesh_destroy(&nav.detour_mesh)
  nav^ = {}
}

// Closest point on the mesh within `extents` of `position`.
nearest_point :: proc(
  nav: ^NavMesh,
  position: [3]f32,
  extents: [3]f32 = {2, 4, 2},
) -> (
  point: [3]f32,
  ok: bool,
) {
  status, ref, pos := detour.find_nearest_poly(&nav.query, position, extents, &nav.filter)
  if !recast.status_succeeded(status) || ref == recast.INVALID_POLY_REF do return {}, false
  return pos, true
}

// Straight-line waypoints from start to end; both ends snap to the mesh
// within `extents`. The caller deletes the path.
find_path :: proc(
  nav: ^NavMesh,
  start, end: [3]f32,
  max_path_length: i32 = 256,
  extents: [3]f32 = {2, 4, 2},
  allocator := context.allocator,
) -> (
  path: [][3]f32,
  ok: bool,
) #optional_ok {
  status, start_ref, start_pos := detour.find_nearest_poly(&nav.query, start, extents, &nav.filter)
  if !recast.status_succeeded(status) || start_ref == recast.INVALID_POLY_REF do return nil, false
  end_ref: recast.Poly_Ref
  end_pos: [3]f32
  status, end_ref, end_pos = detour.find_nearest_poly(&nav.query, end, extents, &nav.filter)
  if !recast.status_succeeded(status) || end_ref == recast.INVALID_POLY_REF do return nil, false
  polys := make([]recast.Poly_Ref, max_path_length, context.temp_allocator)
  path_status, poly_count := detour.find_path(
    &nav.query,
    start_ref,
    end_ref,
    start_pos,
    end_pos,
    &nav.filter,
    polys,
    max_path_length,
  )
  if !recast.status_succeeded(path_status) || poly_count == 0 do return nil, false
  straight := make([]detour.Straight_Path_Point, max_path_length, context.temp_allocator)
  straight_status, count := detour.find_straight_path(
    &nav.query,
    start_pos,
    end_pos,
    polys[:poly_count],
    poly_count,
    straight,
    nil,
    nil,
    max_path_length,
    u32(detour.Straight_Path_Options.All_Crossings),
  )
  if !recast.status_succeeded(straight_status) || count == 0 do return nil, false
  path = make([][3]f32, count, allocator)
  for &p, i in path do p = straight[i].pos
  return path, true
}

// Triangulated polygons of the built mesh, for debug drawing. Caller deletes
// both slices.
debug_triangles :: proc(
  nav: ^NavMesh,
  allocator := context.allocator,
) -> (
  positions: [][3]f32,
  indices: []u32,
) {
  verts := make([dynamic][3]f32, 0, 4096, allocator)
  tris := make([dynamic]u32, 0, 16384, allocator)
  for i in 0 ..< nav.detour_mesh.max_tiles {
    tile := &nav.detour_mesh.tiles[i]
    if tile.header == nil do continue
    base := u32(len(verts))
    for v in 0 ..< tile.header.vert_count do append(&verts, tile.verts[v])
    for poly_idx in 0 ..< tile.header.poly_count {
      poly := &tile.polys[poly_idx]
      for j in 1 ..< int(poly.vert_count) - 1 {
        append(&tris, base + u32(poly.verts[0]), base + u32(poly.verts[j]), base + u32(poly.verts[j + 1]))
      }
    }
  }
  return verts[:], tris[:]
}
