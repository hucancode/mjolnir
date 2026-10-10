package bake

import ".."
import "core:math"
import "core:testing"

@(test)
test_raycast_hits_plane :: proc(t: ^testing.T) {
  verts := [][3]f32{{-10, 0, -10}, {10, 0, -10}, {10, 0, 10}, {-10, 0, 10}}
  indices := []i32{0, 2, 1, 0, 3, 2}
  areas := []u8{63, 63}
  nav: navigation.NavMesh
  testing.expect(t, build(&nav, {vertices = verts, indices = indices, area_types = areas}), "build")
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
