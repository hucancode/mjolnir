#+build !js
#+private
package render

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_cube_generation :: proc(t: ^testing.T) {
  cube := make_cube()
  defer geometry_destroy(cube)
  testing.expect_value(t, len(cube.vertices), 24) // 6 faces * 4 vertices
  testing.expect_value(t, len(cube.indices), 36) // 6 faces * 2 triangles * 3 indices
  aabb := aabb_from_vertices(cube.vertices)
  testing.expect_value(t, aabb.min, [3]f32{-1, -1, -1})
  testing.expect_value(t, aabb.max, [3]f32{1, 1, 1})
}

@(test)
test_sphere_generation :: proc(t: ^testing.T) {
  sphere := make_sphere(16, 16, 1.0)
  defer geometry_destroy(sphere)
  expected_vertices := (16 + 1) * (16 + 1)
  expected_indices := 16 * 16 * 6
  testing.expect_value(t, len(sphere.vertices), expected_vertices)
  testing.expect_value(t, len(sphere.indices), expected_indices)
  // Check that all vertices are approximately on unit sphere
  for vertex in sphere.vertices {
    distance := linalg.length(vertex.position)
    testing.expect(t, abs(distance - 1.0) < math.F32_EPSILON)
  }
  aabb := aabb_from_vertices(sphere.vertices)
  testing.expect_value(t, aabb.min, [3]f32{-1, -1, -1})
  testing.expect_value(t, aabb.max, [3]f32{1, 1, 1})
}

@(test)
test_flat_quad_aabb_has_thickness :: proc(t: ^testing.T) {
  quad := make_quad()
  defer geometry_destroy(quad)
  aabb := aabb_from_vertices(quad.vertices)
  testing.expect(t, aabb.max.y - aabb.min.y >= AABB_MIN_EXTENT - 1e-6)
  testing.expect_value(t, aabb.max.x, 1)
}

@(test)
test_builders_generate_tangents :: proc(t: ^testing.T) {
  shapes := [?]Geometry{make_cube(), make_quad(), make_sphere(), make_cone(), make_capsule(), make_torus(), make_cylinder()}
  for g, s in shapes {
    defer geometry_destroy(g)
    for v, i in g.vertices {
      ok := abs(linalg.length(v.tangent.xyz) - 1) < 1e-3 && v.tangent.w == 1
      testing.expectf(t, ok, "shape %d vertex %d tangent %v", s, i, v.tangent)
      if !ok do break
    }
  }
}
