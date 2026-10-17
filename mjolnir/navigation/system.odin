package navigation

import "core:log"
import "core:math"
import "core:math/linalg"
import "../geometry"
import "detour"

// NavMesh is a navigation mesh plus the query used for path and point lookups. The detour
// fields are exposed for advanced use: navigation/crowd steers on detour_mesh.
NavMesh :: struct {
  detour_mesh: detour.Nav_Mesh,
  query:       detour.Nav_Mesh_Query,
  filter:      detour.Query_Filter,
}

// destroy frees the mesh, its query and the tile data.
destroy :: proc(self: ^NavMesh) {
  detour.nav_mesh_query_destroy(&self.query)
  detour.nav_mesh_destroy(&self.detour_mesh)
  self^ = {}
}

// save encodes the mesh tiles in the detour .navmesh format, in memory the caller frees
// (platform.write_file stores it).
save :: proc(self: ^NavMesh, allocator := context.allocator) -> []u8 {
  return detour.save_navmesh(&self.detour_mesh, allocator)
}

// init decodes a mesh encoded by save or baked by navigation/bake, replacing any previous mesh.
init :: proc(self: ^NavMesh, data: []u8, max_query_nodes: i32 = 2048) -> bool {
  mesh := detour.load_navmesh(data) or_return
  destroy(self)
  self.detour_mesh = mesh^
  free(mesh)
  if status := detour.nav_mesh_query_init(&self.query, &self.detour_mesh, max_query_nodes); !detour.status_succeeded(status) {
    log.errorf("Failed to initialize navigation mesh query: %v", status)
    destroy(self)
    return false
  }
  detour.query_filter_init(&self.filter)
  return true
}

// nearest_point returns the closest mesh point within extents of position.
nearest_point :: proc(
  self: ^NavMesh,
  position: [3]f32,
  extents: [3]f32 = {2, 4, 2},
) -> (
  point: [3]f32,
  ok: bool,
) {
  status, ref, pos := detour.find_nearest_poly(&self.query, position, extents, &self.filter)
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
  origin, dir := ray.origin, ray.direction
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
          if t, hit := ray_triangle(origin, dir, v0, v1, v2); hit && t < best {
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
        if t, hit := ray_triangle(origin, dir, v[0], v[1], v[2]); hit && t < best {
          best = t
          ok = true
        }
      }
    }
  }
  if !ok do return {}, false
  return origin + dir * best, true
}

@(private = "file")
ray_triangle :: proc "contextless" (origin, dir, v0, v1, v2: [3]f32) -> (t: f32, hit: bool) {
  e1 := v1 - v0
  e2 := v2 - v0
  h := linalg.cross(dir, e2)
  a := linalg.dot(e1, h)
  if abs(a) < 1e-8 do return 0, false
  f := 1 / a
  s := origin - v0
  u := f * linalg.dot(s, h)
  if u < 0 || u > 1 do return 0, false
  q := linalg.cross(s, e1)
  v := f * linalg.dot(dir, q)
  if v < 0 || u + v > 1 do return 0, false
  t = f * linalg.dot(e2, q)
  return t, t > 0
}

// find_path returns straight-line waypoints from start to end; both ends snap to the mesh
// within `extents`. The caller deletes the path.
find_path :: proc(
  self: ^NavMesh,
  start, end: [3]f32,
  max_path_length: i32 = 256,
  extents: [3]f32 = {2, 4, 2},
  allocator := context.allocator,
) -> (
  path: [][3]f32,
  ok: bool,
) #optional_ok {
  status, start_ref, start_pos := detour.find_nearest_poly(&self.query, start, extents, &self.filter)
  if !detour.status_succeeded(status) || start_ref == detour.INVALID_POLY_REF do return nil, false
  end_ref: detour.Poly_Ref
  end_pos: [3]f32
  status, end_ref, end_pos = detour.find_nearest_poly(&self.query, end, extents, &self.filter)
  if !detour.status_succeeded(status) || end_ref == detour.INVALID_POLY_REF do return nil, false
  polys := make([]detour.Poly_Ref, max_path_length, context.temp_allocator)
  path_status, poly_count := detour.find_path(
    &self.query,
    start_ref,
    end_ref,
    start_pos,
    end_pos,
    &self.filter,
    polys,
    max_path_length,
  )
  if !detour.status_succeeded(path_status) || poly_count == 0 do return nil, false
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
  return path, true
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
