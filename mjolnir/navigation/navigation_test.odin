#+build !js
#+private
package navigation

import "core:math"
import "core:testing"

@(test)
test_raycast_hits_plane :: proc(t: ^testing.T) {
  nav: NavMesh
  build_plane(t, &nav)
  defer destroy(&nav)

  p, ok := raycast(&nav, {{2, 10, 3}, {0, -1, 0}})
  testing.expect(t, ok, "downward ray must hit")
  testing.expectf(t, math.abs(p.x - 2) < 1e-3 && math.abs(p.z - 3) < 1e-3 && math.abs(p.y) < 0.5, "hit at %v", p)

  _, up := raycast(&nav, {{2, 10, 3}, {0, 1, 0}})
  testing.expect(t, !up, "upward ray must miss")
  _, far := raycast(&nav, {{50, 10, 50}, {0, -1, 0}})
  testing.expect(t, !far, "ray outside the mesh must miss")
  _, short := raycast(&nav, {{2, 10, 3}, {0, -1, 0}}, 5)
  testing.expect(t, !short, "max_t must limit the hit")
}

@(test)
test_save_load_roundtrip :: proc(t: ^testing.T) {
  nav: NavMesh
  build_plane(t, &nav)
  defer destroy(&nav)
  data := save(&nav)
  defer delete(data)
  loaded: NavMesh
  testing.expect(t, load(&loaded, data), "load")
  defer destroy(&loaded)

  a, _ := debug_triangles(&nav, context.temp_allocator)
  b, _ := debug_triangles(&loaded, context.temp_allocator)
  testing.expect_value(t, len(b), len(a))
  path_a := find_path(&nav, {-8, 0, -8}, {8, 0, 8}, allocator = context.temp_allocator)
  path_b := find_path(&loaded, {-8, 0, -8}, {8, 0, 8}, allocator = context.temp_allocator)
  testing.expect(t, len(path_b) > 0 && len(path_b) == len(path_a), "loaded mesh must give the same path")
  for p, i in path_b do testing.expectf(t, p == path_a[i], "waypoint %d: %v != %v", i, p, path_a[i])
}

// test_plane.navmesh is a 20x20 walkable plane centered at the origin, baked by navigation/bake
@(private = "file")
build_plane :: proc(t: ^testing.T, nav: ^NavMesh) {
  testing.expect(t, load(nav, #load("test_plane.navmesh")), "load the plane fixture")
}
