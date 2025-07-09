package geometry

import "core:log"
import linalg "core:math/linalg"

// Plane is represented as a linalg.Vector4f32 {A, B, C, D}
// for the plane equation Ax + By + Cz + D = 0.
// The normal {A, B, C} is assumed to point "inwards" for a convex volume.
Plane :: [4]f32

Frustum :: struct {
  planes: [6]Plane,
}

make_frustum :: proc(view_projection_matrix: linalg.Matrix4f32) -> Frustum {
  m := linalg.transpose(view_projection_matrix)
  // Each plane is a Vec4: a*x + b*y + c*z + d = 0
  planes := [6]Plane {
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
  // log.infof("Make frustum with: %v, m0 %v, m1 %v, m2 %v, m3 %v -> %v", m, m[0], m[1], m[2], m[3], planes)
  return Frustum{planes}
}

signed_distance_to_plane :: proc(
  plane: Plane,
  point: linalg.Vector3f32,
) -> f32 {
  return linalg.dot(plane.xyz, point) + plane.w
}

frustum_test_point :: proc(frustum: Frustum, p: [3]f32) -> bool {
  for plane in frustum.planes {
    distance := linalg.dot(plane.xyz, p) + plane.w
    if distance < 0.0 {
      return false
    }
  }
  return true
}
// test_aabb_frustum tests if an Axis-Aligned Bounding Box (AABB) intersects or is contained within a Frustum.
// Assumes Frustum planes have normals pointing inwards.
// Returns true if the AABB is (at least partially) inside the frustum, false if completely outside.
frustum_test_aabb :: proc(frustum: Frustum, aabb: Aabb) -> bool {
  if frustum_test_point(frustum, {aabb.min.x, aabb.min.y, aabb.min.z}) do return true
  if frustum_test_point(frustum, {aabb.max.x, aabb.min.y, aabb.min.z}) do return true
  if frustum_test_point(frustum, {aabb.min.x, aabb.max.y, aabb.min.z}) do return true
  if frustum_test_point(frustum, {aabb.min.x, aabb.min.y, aabb.max.z}) do return true
  if frustum_test_point(frustum, {aabb.max.x, aabb.max.y, aabb.min.z}) do return true
  if frustum_test_point(frustum, {aabb.max.x, aabb.min.y, aabb.max.z}) do return true
  if frustum_test_point(frustum, {aabb.min.x, aabb.max.y, aabb.max.z}) do return true
  if frustum_test_point(frustum, {aabb.max.x, aabb.max.y, aabb.max.z}) do return true
  return false
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
  transform_matrix: linalg.Matrix4f32,
) -> (
  ret: Aabb,
) {
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
  ret = AABB_UNDEFINED
  for corner in corners {
    transformed_corner := transform_matrix * corner
    ret.min = linalg.min(ret.min, transformed_corner.xyz)
    ret.max = linalg.max(ret.max, transformed_corner.xyz)
  }
  return
}
