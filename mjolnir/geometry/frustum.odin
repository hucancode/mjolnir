package geometry

import "core:math/linalg"

// Plane is represented as a [4]f32 {A, B, C, D}
// for the plane equation Ax + By + Cz + D = 0.
// The normal {A, B, C} is assumed to point "inwards" for a convex volume.
Plane :: [4]f32

Frustum :: struct {
  planes: [6]Plane,
}

make_frustum :: proc(m: matrix[4, 4]f32) -> Frustum {
  // Each plane is a Vec4: a*x + b*y + c*z + d = 0
  x_axis := [4]f32{m[0, 0], m[0, 1], m[0, 2], m[0, 3]}
  y_axis := [4]f32{m[1, 0], m[1, 1], m[1, 2], m[1, 3]}
  z_axis := [4]f32{m[2, 0], m[2, 1], m[2, 2], m[2, 3]}
  origin := [4]f32{m[3, 0], m[3, 1], m[3, 2], m[3, 3]}
  planes := [6]Plane {
    // Left
    origin + x_axis,
    // Right
    origin - x_axis,
    // Bottom
    origin + y_axis,
    // Top
    origin - y_axis,
    // Near
    origin + z_axis,
    // Far
    origin - z_axis,
  }
  for &plane in planes {
    mag := linalg.length(plane.xyz)
    if mag > 1e-6 {
      plane /= mag
    }
  }
  return Frustum{planes}
}

signed_distance_to_plane :: proc "contextless" (
  plane: Plane,
  point: [3]f32,
) -> f32 {
  return linalg.dot(plane.xyz, point) + plane.w
}

frustum_test_point :: proc "contextless" (
  frustum: Frustum,
  p: [3]f32,
) -> bool {
  for plane in frustum.planes {
    if signed_distance_to_plane(plane, p) < 0 do return false
  }
  return true
}
// test_aabb_frustum tests if an Axis-Aligned Bounding Box (AABB) intersects or is contained within a Frustum.
// Assumes Frustum planes have normals pointing inwards.
frustum_test_aabb :: proc "contextless" (
  frustum: Frustum,
  aabb: Aabb,
) -> bool {
  // For each frustum plane, test if the AABB is completely on the negative side
  for plane in frustum.planes {
    // Find the "positive" and "negative" vertices of the AABB relative to the plane normal
    // The positive vertex is the one furthest in the direction of the plane normal
    positive_vertex: [3]f32
    negative_vertex: [3]f32
    // For each axis, choose min or max based on plane normal direction
    if plane.x >= 0 {
      positive_vertex.x = aabb.max.x
      negative_vertex.x = aabb.min.x
    } else {
      positive_vertex.x = aabb.min.x
      negative_vertex.x = aabb.max.x
    }
    if plane.y >= 0 {
      positive_vertex.y = aabb.max.y
      negative_vertex.y = aabb.min.y
    } else {
      positive_vertex.y = aabb.min.y
      negative_vertex.y = aabb.max.y
    }
    if plane.z >= 0 {
      positive_vertex.z = aabb.max.z
      negative_vertex.z = aabb.min.z
    } else {
      positive_vertex.z = aabb.min.z
      negative_vertex.z = aabb.max.z
    }
    // If the positive vertex is on the negative side of the plane, the entire AABB is outside
    if signed_distance_to_plane(plane, positive_vertex) < 0 do return false
  }
  return true
}

frustum_test_sphere :: proc "contextless" (
  frustum: Frustum,
  center: [3]f32,
  radius: f32,
) -> bool {
  for plane_vec in frustum.planes {
    dist := signed_distance_to_plane(plane_vec, center)
    if dist < -radius do return false
  }
  return true
}

aabb_transform :: proc "contextless" (
  aabb: Aabb,
  transform: matrix[4, 4]f32,
) -> (
  ret: Aabb,
) {
  min_p := aabb.min
  max_p := aabb.max
  corners: [8][4]f32
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
    transformed_corner := transform * corner
    ret.min = linalg.min(ret.min, transformed_corner.xyz)
    ret.max = linalg.max(ret.max, transformed_corner.xyz)
  }
  return
}

frustum_corners_world :: proc(
  view_matrix: matrix[4, 4]f32,
  proj_matrix: matrix[4, 4]f32,
) -> [8][3]f32 {
  view_proj := proj_matrix * view_matrix
  inv_view_proj := linalg.matrix4_inverse(view_proj)
  ndc_corners := [8][4]f32 {
    {-1, -1, 0, 1},
    {1, -1, 0, 1},
    {1, 1, 0, 1},
    {-1, 1, 0, 1},
    {-1, -1, 1, 1},
    {1, -1, 1, 1},
    {1, 1, 1, 1},
    {-1, 1, 1, 1},
  }
  world_corners: [8][3]f32
  for ndc, i in ndc_corners {
    world_homogeneous := inv_view_proj * ndc
    world_corners[i] = world_homogeneous.xyz / world_homogeneous.w
  }
  return world_corners
}
