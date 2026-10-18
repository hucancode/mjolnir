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
  append_box(&b, {0, 1, 0}, {2, 1, 2}, is_obstacle = true)
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
