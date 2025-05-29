package geometry

import "core:fmt"
import linalg "core:math/linalg"

// Plane is represented as a linalg.Vector4f32 {A, B, C, D}
// for the plane equation Ax + By + Cz + D = 0.
// The normal {A, B, C} is assumed to point "inwards" for a convex volume.
Plane :: linalg.Vector4f32

Frustum :: struct {
  planes: [6]Plane,
}


make_frustum :: proc(view_projection_matrix: linalg.Matrix4f32) -> Frustum {
  m := linalg.transpose(view_projection_matrix)
  // Each plane is a Vec4: a*x + b*y + c*z + d = 0
  planes := [6]linalg.Vector4f32 {
    // Left
    m[3] + m[0],
    // Right
    m[3] - m[0],
    // Bottom
    m[3] + m[1],
    // Top
    m[3] - m[1],
    // Near
    m[3] + m[2],
    // Far
    m[3] - m[2],
  }

  for &plane in planes {
    mag := linalg.length(plane.xyz)
    if mag > 1e-6 {
      plane /= mag
    }
  }
  // fmt.printfln("Make frustum with: %v, m0 %v, m1 %v, m2 %v, m3 %v -> %v", m, m[0], m[1], m[2], m[3], planes)
  return Frustum{planes}
}

signed_distance_to_plane :: proc(
  plane: Plane,
  point: linalg.Vector3f32,
) -> f32 {
  return linalg.dot(plane.xyz, point) + plane.w
}

// test_aabb_frustum tests if an Axis-Aligned Bounding Box (AABB) intersects or is contained within a Frustum.
// Assumes Frustum planes have normals pointing inwards.
// Returns true if the AABB is (at least partially) inside the frustum, false if completely outside.
frustum_test_aabb :: proc(
  frustum: ^Frustum,
  aabb_min: linalg.Vector3f32,
  aabb_max: linalg.Vector3f32,
) -> bool {
  for plane_vec in frustum.planes {
    p_vertex: linalg.Vector3f32
    p_vertex.x = plane_vec.x > 0.0 ? aabb_max.x : aabb_min.x
    p_vertex.y = plane_vec.y > 0.0 ? aabb_max.y : aabb_min.y
    p_vertex.z = plane_vec.z > 0.0 ? aabb_max.z : aabb_min.z

    if signed_distance_to_plane(plane_vec, p_vertex) < 0.0 {
      return false
    }
  }
  return true // AABB is inside or intersects all planes
}

frustum_test_sphere :: proc(
  sphere_center: linalg.Vector3f32,
  sphere_radius: f32,
  frustum: ^Frustum,
) -> bool {
  for plane_vec in frustum.planes {
    dist := signed_distance_to_plane(plane_vec, sphere_center)
    if dist < -sphere_radius {
      return false
    }
  }
  return true // Sphere intersects or is inside all planes
}

// transform_aabb transforms an AABB by a given matrix.
aabb_transform :: proc(
  aabb: Aabb,
  transform_matrix: ^linalg.Matrix4f32,
) -> Aabb {
  min_p := aabb.min
  max_p := aabb.max

  corners: [8]linalg.Vector4f32
  corners[0] = {min_p.x, min_p.y, min_p.z, 1.0}
  corners[1] = {max_p.x, min_p.y, min_p.z, 1.0}
  corners[2] = {min_p.x, max_p.y, min_p.z, 1.0}
  corners[3] = {min_p.x, min_p.y, max_p.z, 1.0}
  corners[4] = {max_p.x, max_p.y, min_p.z, 1.0}
  corners[5] = {max_p.x, min_p.y, max_p.z, 1.0}
  corners[6] = {min_p.x, max_p.y, max_p.z, 1.0}
  corners[7] = {max_p.x, max_p.y, max_p.z, 1.0}

  F32_MIN :: -3.40282347E+38
  F32_MAX :: 3.40282347E+38
  new_aabb_min := linalg.Vector3f32{F32_MAX, F32_MAX, F32_MAX}
  new_aabb_max := linalg.Vector3f32{F32_MIN, F32_MIN, F32_MIN}

  for corner in corners {
    transformed_corner := transform_matrix^ * corner
    transformed_vec3 := linalg.Vector3f32{transformed_corner.x, transformed_corner.y, transformed_corner.z}
    new_aabb_min = linalg.min(new_aabb_min, transformed_vec3)
    new_aabb_max = linalg.max(new_aabb_max, transformed_vec3)
  }
  return Aabb{min = new_aabb_min, max = new_aabb_max}
}
