package navigation

import "core:log"
import "core:math"
import "core:math/linalg"
import "../geometry"
import "detour"

// MAX_FILTERS is how many query filters a NavMesh holds.
MAX_FILTERS :: 16

// NavMesh is a navigation mesh plus the query used for path and point lookups. filters[i] is
// what queries and agents of filter i may cross and at what cost per area (detour.Query_Filter:
// area_cost by the area bake gave each polygon); navmesh_init resets every one to cost 1 for
// every area. Edit them any time.
NavMesh :: struct {
  filters: [MAX_FILTERS]detour.Query_Filter,
  using _: NavMesh_State,
}

@(private)
NavMesh_State :: struct {
  detour_mesh: detour.Nav_Mesh,
  query:       detour.Nav_Mesh_Query,
}

// navmesh_destroy frees the mesh, its query and the tile data.
navmesh_destroy :: proc(self: ^NavMesh) {
  detour.nav_mesh_query_destroy(&self.query)
  detour.nav_mesh_destroy(&self.detour_mesh)
  self.detour_mesh, self.query = {}, {}
}

// save encodes the mesh tiles in the detour .navmesh format, in memory the caller frees.
save :: proc(self: ^NavMesh, allocator := context.allocator) -> []u8 {
  return detour.save_navmesh(&self.detour_mesh, allocator)
}

// navmesh_init decodes a mesh encoded by save or baked by bake, replacing any
// previous mesh; a crowd on it follows on its next update.
navmesh_init :: proc(self: ^NavMesh, data: []u8, max_query_nodes: i32 = 2048) -> bool {
  mesh := detour.load_navmesh(data) or_return
  navmesh_destroy(self)
  self.detour_mesh = mesh^
  free(mesh)
  if status := detour.nav_mesh_query_init(&self.query, &self.detour_mesh, max_query_nodes); !detour.status_succeeded(status) {
    log.errorf("Failed to initialize navigation mesh query: %v", status)
    navmesh_destroy(self)
    return false
  }
  for &f in self.filters do detour.query_filter_init(&f)
  return true
}

// nearest_point returns the closest point within extents of position that filter allows.
nearest_point :: proc(
  self: ^NavMesh,
  position: [3]f32,
  extents: [3]f32 = {2, 4, 2},
  filter: u8 = 0,
) -> (
  point: [3]f32,
  ok: bool,
) {
  status, ref, pos := detour.find_nearest_poly(&self.query, position, extents, &self.filters[filter % MAX_FILTERS])
  if !detour.status_succeeded(status) || ref == detour.INVALID_POLY_REF do return {}, false
  return pos, true
}

// raycast returns the nearest point where ray.origin + t * ray.direction (0 < t < max_t) hits
// the mesh surface. Tests the detail triangles of every polygon.
raycast :: proc(
  self: ^NavMesh,
  ray: geometry.Ray,
  max_t: f32 = math.F32_MAX,
) -> (
  point: [3]f32,
  ok: bool,
) {
  best := max_t
  for i in 0 ..< self.detour_mesh.max_tiles {
    tile := &self.detour_mesh.tiles[i]
    if tile.header == nil do continue
    for poly_idx in 0 ..< int(tile.header.poly_count) {
      poly := &tile.polys[poly_idx]
      if detour.poly_get_type(poly) == detour.DT_POLYTYPE_OFFMESH_CONNECTION do continue
      if poly_idx >= len(tile.detail_meshes) {
        for j in 1 ..< int(poly.vert_count) - 1 {
          v0 := tile.verts[poly.verts[0]]
          v1 := tile.verts[poly.verts[j]]
          v2 := tile.verts[poly.verts[j + 1]]
          if t, hit := geometry.ray_triangle_intersection(ray, v0, v1, v2); hit && t < best {
            best = t
            ok = true
          }
        }
        continue
      }
      pd := &tile.detail_meshes[poly_idx]
      for k in 0 ..< u32(pd.tri_count) {
        tri := tile.detail_tris[pd.tri_base + k]
        v: [3][3]f32
        for j in 0 ..< 3 {
          if tri[j] < poly.vert_count {
            v[j] = tile.verts[poly.verts[tri[j]]]
          } else {
            v[j] = tile.detail_verts[pd.vert_base + u32(tri[j] - poly.vert_count)]
          }
        }
        if t, hit := geometry.ray_triangle_intersection(ray, v[0], v[1], v[2]); hit && t < best {
          best = t
          ok = true
        }
      }
    }
  }
  if !ok do return {}, false
  return ray.origin + ray.direction * best, true
}

// find_path returns straight-line waypoints from start to end, the cheapest way filter allows;
// both ends snap to the mesh within `extents`; nil when either end is off the mesh. partial when
// end cannot be reached: the path then ends as near it as the mesh goes. The caller deletes the
// path.
find_path :: proc(
  self: ^NavMesh,
  start, end: [3]f32,
  max_path_length: i32 = 256,
  extents: [3]f32 = {2, 4, 2},
  filter: u8 = 0,
  allocator := context.allocator,
) -> (
  path: [][3]f32,
  partial: bool,
) #optional_ok {
  filter := &self.filters[filter % MAX_FILTERS]
  status, start_ref, start_pos := detour.find_nearest_poly(&self.query, start, extents, filter)
  if !detour.status_succeeded(status) || start_ref == detour.INVALID_POLY_REF do return
  end_ref: detour.Poly_Ref
  end_pos: [3]f32
  status, end_ref, end_pos = detour.find_nearest_poly(&self.query, end, extents, filter)
  if !detour.status_succeeded(status) || end_ref == detour.INVALID_POLY_REF do return
  polys := make([]detour.Poly_Ref, max_path_length, context.temp_allocator)
  path_status, poly_count := detour.find_path(
    &self.query,
    start_ref,
    end_ref,
    start_pos,
    end_pos,
    filter,
    polys,
    max_path_length,
  )
  if !detour.status_succeeded(path_status) || poly_count == 0 do return
  partial = .Partial_Result in path_status
  straight := make([]detour.Straight_Path_Point, max_path_length, context.temp_allocator)
  straight_status, count := detour.find_straight_path(
    &self.query,
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
  if !detour.status_succeeded(straight_status) || count == 0 do return nil, false
  path = make([][3]f32, count, allocator)
  for &p, i in path do p = straight[i].pos
  return path, partial
}

// follow moves position up to `step` along path, from waypoint next on, skipping waypoints within
// `reached` of it; false once it has reached the last one.
follow :: proc(path: [][3]f32, next: ^int, position: ^[3]f32, step: f32, reached: f32 = 0.3) -> (moving: bool) {
  for next^ < len(path) && linalg.length(path[next^] - position^) < reached do next^ += 1
  if next^ >= len(path) do return false
  to_waypoint := path[next^] - position^
  distance := linalg.length(to_waypoint)
  position^ += to_waypoint / distance * min(step, distance)
  return true
}

// debug_triangles returns the triangulated mesh polygons for debug drawing. Caller deletes
// both slices.
debug_triangles :: proc(
  self: ^NavMesh,
  allocator := context.allocator,
) -> (
  positions: [][3]f32,
  indices: []u32,
) {
  verts := make([dynamic][3]f32, 0, 4096, allocator)
  tris := make([dynamic]u32, 0, 16384, allocator)
  for i in 0 ..< self.detour_mesh.max_tiles {
    tile := &self.detour_mesh.tiles[i]
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

// destroy frees a NavMesh, a crowd or a crowd agent, as navmesh_destroy, crowd_destroy and
// agent_destroy do.
destroy :: proc {
  navmesh_destroy,
  crowd_destroy,
  agent_destroy,
}
