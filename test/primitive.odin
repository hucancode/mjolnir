package tests

import "../mjolnir/geometry"
import "core:testing"
import "core:math"
import linalg "core:math/linalg"

@(test)
test_cube_generation :: proc(t: ^testing.T) {
    cube := geometry.make_cube()
    defer geometry.delete_geometry(cube)
    testing.expect_value(t, len(cube.vertices), 24) // 6 faces * 4 vertices
    testing.expect_value(t, len(cube.indices), 36)  // 6 faces * 2 triangles * 3 indices
    // Check AABB
    testing.expect_value(t, cube.aabb.min, [3]f32{-1, -1, -1})
    testing.expect_value(t, cube.aabb.max, [3]f32{1, 1, 1})
}

@(test)
test_sphere_generation :: proc(t: ^testing.T) {
    sphere := geometry.make_sphere(16, 16, 1.0)
    defer geometry.delete_geometry(sphere)
    expected_vertices := (16 + 1) * (16 + 1)
    expected_indices := 16 * 16 * 6
    testing.expect_value(t, len(sphere.vertices), expected_vertices)
    testing.expect_value(t, len(sphere.indices), expected_indices)
    // Check that all vertices are approximately on unit sphere
    for vertex in sphere.vertices {
        distance := linalg.length(vertex.position)
        testing.expect(t, abs(distance - 1.0) < math.F32_EPSILON)
    }
    testing.expect_value(t, sphere.aabb.min, [3]f32{-1, -1, -1})
    testing.expect_value(t, sphere.aabb.max, [3]f32{1, 1, 1})
}

@(test)
test_triangle_winding_order :: proc(t: ^testing.T) {
    triangle := geometry.make_triangle()
    defer geometry.delete_geometry(triangle)
    testing.expect_value(t, len(triangle.indices), 3)
    // Verify counter-clockwise winding
    v0 := triangle.vertices[triangle.indices[0]].position
    v1 := triangle.vertices[triangle.indices[1]].position
    v2 := triangle.vertices[triangle.indices[2]].position
    edge1 := v1 - v0
    edge2 := v2 - v0
    normal := linalg.cross(edge1, edge2)
    // Normal should point in positive Z direction for CCW winding
    testing.expect(t, normal.z > 0)
}
