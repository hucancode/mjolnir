#+build !js
#+private
package bake

import "../detour"
import "core:testing"

@(test)
test_build_bytes_load_as_navmesh :: proc(t: ^testing.T) {
  b: NavGeometryBuilder
  defer builder_destroy(&b)
  append_triangles(&b, {{-10, 0, -10}, {10, 0, -10}, {10, 0, 10}, {-10, 0, 10}}, {0, 2, 1, 0, 3, 2})
  data, ok := build(&b)
  testing.expect(t, ok, "build")
  defer delete(data)
  mesh, loaded := detour.load_navmesh(data)
  testing.expect(t, loaded, "the baked bytes load as a navmesh")
  if !loaded do return
  defer {
    detour.nav_mesh_destroy(mesh)
    free(mesh)
  }
  query: detour.Nav_Mesh_Query
  testing.expect(t, detour.status_succeeded(detour.nav_mesh_query_init(&query, mesh, 256)), "query")
  defer detour.nav_mesh_query_destroy(&query)
  filter: detour.Query_Filter
  detour.query_filter_init(&filter)
  status, ref, _ := detour.find_nearest_poly(&query, {3, 0, -4}, {2, 4, 2}, &filter)
  testing.expect(t, detour.status_succeeded(status) && ref != detour.INVALID_POLY_REF, "the plane is walkable")
}

@(test)
test_append_box_ground_and_obstacle :: proc(t: ^testing.T) {
  b: NavGeometryBuilder
  defer builder_destroy(&b)
  append_box(&b, {0, -0.5, 0}, {10, 0.5, 10})
  append_box(&b, {0, 1, 0}, {2, 1, 2}, area = AREA_BLOCKED)
  data, ok := build(&b)
  testing.expect(t, ok, "build")
  defer delete(data)
  mesh, loaded := detour.load_navmesh(data)
  testing.expect(t, loaded, "the baked bytes load as a navmesh")
  if !loaded do return
  defer {
    detour.nav_mesh_destroy(mesh)
    free(mesh)
  }
  query: detour.Nav_Mesh_Query
  testing.expect(t, detour.status_succeeded(detour.nav_mesh_query_init(&query, mesh, 256)), "query")
  defer detour.nav_mesh_query_destroy(&query)
  filter: detour.Query_Filter
  detour.query_filter_init(&filter)
  status, ref, _ := detour.find_nearest_poly(&query, {6, 0, 6}, {0.5, 1, 0.5}, &filter)
  testing.expect(t, detour.status_succeeded(status) && ref != detour.INVALID_POLY_REF, "the slab's top is walkable")
  status, ref, _ = detour.find_nearest_poly(&query, {0, 0, 0}, {0.5, 1, 0.5}, &filter)
  testing.expect(t, ref == detour.INVALID_POLY_REF, "the obstacle's footprint is not walkable")
}

// A level of more than 1024 polygons: every polygon's ref must decode back to it.
@(test)
test_build_over_1024_polygons :: proc(t: ^testing.T) {
  b: NavGeometryBuilder
  defer builder_destroy(&b)
  append_box(&b, {0, -0.5, 0}, {80, 0.5, 80})
  for x in 0 ..< 32 do for z in 0 ..< 32 {
    append_box(&b, {f32(x) * 5 - 77.5, 1, f32(z) * 5 - 77.5}, {0.8, 1, 0.8}, area = AREA_BLOCKED)
  }
  data, ok := build(&b)
  testing.expect(t, ok, "build")
  if !ok do return
  defer delete(data)
  mesh, loaded := detour.load_navmesh(data)
  testing.expect(t, loaded, "the baked bytes load as a navmesh")
  if !loaded do return
  defer {
    detour.nav_mesh_destroy(mesh)
    free(mesh)
  }
  tile := &mesh.tiles[0]
  testing.expectf(t, tile.header.poly_count > 1024, "the level must have over 1024 polygons, has %d", tile.header.poly_count)
  query: detour.Nav_Mesh_Query
  testing.expect(t, detour.status_succeeded(detour.nav_mesh_query_init(&query, mesh, 256)), "query")
  defer detour.nav_mesh_query_destroy(&query)
  filter: detour.Query_Filter
  detour.query_filter_init(&filter)
  // the refs queries hand out lead back to polygons, past index 1024 too
  highest := -1
  for x in 0 ..< 64 do for z in 0 ..< 64 {
    p := [3]f32{f32(x) * 2.5 - 78.75, 0, f32(z) * 2.5 - 78.75}
    status, ref, _ := detour.find_nearest_poly(&query, p, {1, 2, 1}, &filter)
    if !detour.status_succeeded(status) || ref == detour.INVALID_POLY_REF do continue
    _, poly, poly_status := detour.get_tile_and_poly_by_ref(mesh, ref)
    if !detour.status_succeeded(poly_status) {
      testing.expectf(t, false, "the ref found at %v does not decode", p)
      return
    }
    highest = max(highest, int(uintptr(poly) - uintptr(&tile.polys[0])) / size_of(detour.Poly))
  }
  testing.expectf(t, highest >= 1024, "queries must reach polygons past 1024, highest %d", highest)
}
