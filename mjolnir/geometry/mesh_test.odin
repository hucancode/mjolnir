#+build !js
#+private
package geometry

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_cube_generation :: proc(t: ^testing.T) {
  cube := make_cube()
  defer mesh_destroy(cube)
  testing.expect_value(t, len(cube.vertices), 24) // 6 faces * 4 vertices
  testing.expect_value(t, len(cube.indices), 36) // 6 faces * 2 triangles * 3 indices
  aabb := aabb_from_vertices(cube.vertices)
  testing.expect_value(t, aabb.min, [3]f32{-1, -1, -1})
  testing.expect_value(t, aabb.max, [3]f32{1, 1, 1})
}

@(test)
test_sphere_generation :: proc(t: ^testing.T) {
  sphere := make_sphere(16, 16, 1.0)
  defer mesh_destroy(sphere)
  expected_vertices := (16 + 1) * (16 + 1)
  // the triangles touching the poles have no area
  expected_indices := 16 * 16 * 6 - 2 * 16 * 3
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
  defer mesh_destroy(quad)
  aabb := aabb_from_vertices(quad.vertices)
  testing.expect(t, aabb.max.y - aabb.min.y >= AABB_MIN_EXTENT - 1e-6)
  testing.expect_value(t, aabb.max.x, 1)
}

@(test)
test_builders_generate_tangents :: proc(t: ^testing.T) {
  shapes := [?]Mesh{make_cube(), make_quad(), make_sphere(), make_sphere(faceted = true), make_cone(), make_cone(top_radius = 0.5), make_capsule(), make_torus(), make_cylinder(), make_cylinder(rings = 4, caps = false), make_cylinder(arc = math.PI), make_circle(), make_wedge(), make_wedge(0.5)}
  for g, s in shapes {
    defer mesh_destroy(g)
    for v, i in g.vertices {
      ok := abs(linalg.length(v.tangent.xyz) - 1) < 1e-3 && v.tangent.w == 1
      testing.expectf(t, ok, "shape %d vertex %d tangent %v", s, i, v.tangent)
      if !ok do break
    }
  }
}

// Every triangle winds counter-clockwise seen from where its vertex normals point.
@(private = "file")
expect_outward :: proc(t: ^testing.T, g: Mesh, name: string) {
  for i := 0; i + 2 < len(g.indices); i += 3 {
    a, b, c := g.vertices[g.indices[i]], g.vertices[g.indices[i + 1]], g.vertices[g.indices[i + 2]]
    face := linalg.cross(b.position - a.position, c.position - a.position)
    if linalg.length(face) < 1e-6 do continue
    ok := linalg.dot(face, a.normal + b.normal + c.normal) > 0
    testing.expectf(t, ok, "%s: triangle %d winds against its normals", name, i / 3)
    if !ok do break
  }
}

@(test)
test_builders_wind_outward :: proc(t: ^testing.T) {
  shapes := [?]struct {
    name: string,
    mesh: Mesh,
  } {
    {"cube", make_cube()},
    {"wedge", make_wedge(0.5)},
    {"quad", make_quad()},
    {"billboard", make_billboard_quad()},
    {"sphere", make_sphere()},
    {"faceted sphere", make_sphere(faceted = true)},
    {"cone", make_cone()},
    {"frustum", make_cone(top_radius = 0.5)},
    {"capsule", make_capsule()},
    {"torus", make_torus()},
    {"cylinder", make_cylinder(rings = 3)},
    {"circle", make_circle()},
  }
  for s in shapes {
    expect_outward(t, s.mesh, s.name)
    mesh_destroy(s.mesh)
  }
}

@(test)
test_partial_cylinder_is_closed_and_winds_outward :: proc(t: ^testing.T) {
  g := make_cylinder(segments = 8, arc = math.PI / 2)
  defer mesh_destroy(g)
  open := make_cylinder(segments = 8, arc = math.PI / 2, caps = false)
  defer mesh_destroy(open)
  // two caps of 8 triangles each, and two cut faces
  testing.expect_value(t, len(g.indices), len(open.indices) + 2 * 8 * 3 + 12)
  expect_outward(t, g, "quarter cylinder")
}

@(test)
test_torus_lies_around_z :: proc(t: ^testing.T) {
  g := make_torus(major_radius = 1, minor_radius = 0.25)
  defer mesh_destroy(g)
  aabb := aabb_from_vertices(g.vertices)
  testing.expect(t, abs(aabb.max.z - 0.25) < 1e-4 && abs(aabb.max.x - 1.25) < 1e-4 && abs(aabb.max.y - 1.25) < 1e-4)
}

@(test)
test_merge_places_parts :: proc(t: ^testing.T) {
  parts := [2]Mesh{make_cube(), make_cube()}
  defer for p in parts do mesh_destroy(p)
  placed := [2]Transform{TRANSFORM_IDENTITY, {position = {4, 0, 0}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 2, 1}}}
  g := mesh_merge(parts[:], placed[:])
  defer mesh_destroy(g)
  testing.expect_value(t, len(g.vertices), 48)
  testing.expect_value(t, g.indices[36], 24)
  aabb := aabb_from_vertices(g.vertices)
  testing.expect_value(t, aabb.min, [3]f32{-1, -2, -1})
  testing.expect_value(t, aabb.max, [3]f32{5, 2, 1})
  expect_outward(t, g, "merged")
}
