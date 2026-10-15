#+build !js
package bake

import ".."
import "core:math"
import "core:testing"

@(test)
test_raycast_hits_plane :: proc(t: ^testing.T) {
  nav: navigation.NavMesh
  build_plane(t, &nav)
  defer navigation.destroy(&nav)

  p, ok := navigation.raycast(&nav, {2, 10, 3}, {0, -1, 0})
  testing.expect(t, ok, "downward ray must hit")
  testing.expectf(t, math.abs(p.x - 2) < 1e-3 && math.abs(p.z - 3) < 1e-3 && math.abs(p.y) < 0.5, "hit at %v", p)

  _, up := navigation.raycast(&nav, {2, 10, 3}, {0, 1, 0})
  testing.expect(t, !up, "upward ray must miss")
  _, far := navigation.raycast(&nav, {50, 10, 50}, {0, -1, 0})
  testing.expect(t, !far, "ray outside the mesh must miss")
  _, short := navigation.raycast(&nav, {2, 10, 3}, {0, -1, 0}, 5)
  testing.expect(t, !short, "max_t must limit the hit")
}

@(test)
test_save_load_roundtrip :: proc(t: ^testing.T) {
  nav: navigation.NavMesh
  build_plane(t, &nav)
  defer navigation.destroy(&nav)
  data := navigation.save(&nav)
  defer delete(data)
  loaded: navigation.NavMesh
  testing.expect(t, navigation.load(&loaded, data), "load")
  defer navigation.destroy(&loaded)

  a, _ := navigation.debug_triangles(&nav, context.temp_allocator)
  b, _ := navigation.debug_triangles(&loaded, context.temp_allocator)
  testing.expect_value(t, len(b), len(a))
  path_a := navigation.find_path(&nav, {-8, 0, -8}, {8, 0, 8}, allocator = context.temp_allocator)
  path_b := navigation.find_path(&loaded, {-8, 0, -8}, {8, 0, 8}, allocator = context.temp_allocator)
  testing.expect(t, len(path_b) > 0 && len(path_b) == len(path_a), "loaded mesh must give the same path")
  for p, i in path_b do testing.expectf(t, p == path_a[i], "waypoint %d: %v != %v", i, p, path_a[i])
}

@(private = "file")
build_plane :: proc(t: ^testing.T, nav: ^navigation.NavMesh) {
  b: NavGeometryBuilder
  defer builder_destroy(&b)
  append_triangles(&b, {{-10, 0, -10}, {10, 0, -10}, {10, 0, 10}, {-10, 0, 10}}, {0, 2, 1, 0, 3, 2})
  testing.expect(t, build(nav, &b), "build")
}
