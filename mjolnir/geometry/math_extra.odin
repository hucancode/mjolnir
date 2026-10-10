package geometry

import "core:math"
import "core:math/linalg"

is_identity_quaternion :: proc "contextless" (q: quaternion128) -> bool {
  epsilon :: 1e-6
  return(
    math.abs(q.x) < epsilon &&
    math.abs(q.y) < epsilon &&
    math.abs(q.z) < epsilon &&
    math.abs(q.w - 1.0) < epsilon \
  )
}

// Cross-product matrix: skew(a) * b == cross(a, b)
skew :: #force_inline proc "contextless" (v: [3]f32) -> matrix[3, 3]f32 {
  return matrix[3, 3]f32{
    0, -v.z, v.y,
    v.z, 0, -v.x,
    -v.y, v.x, 0,
  }
}

// Two vectors orthogonal to `normal` and to each other
tangent_basis :: proc "contextless" (normal: [3]f32) -> (t1, t2: [3]f32) {
  t1 = linalg.orthogonal(normal)
  t2 = linalg.cross(normal, t1)
  return
}

// Outward normal of the AABB face nearest to `point` (relative to each
// axis' half extent), for points on or near the surface.
aabb_face_normal :: proc "contextless" (aabb: Aabb, point: [3]f32) -> (normal: [3]f32) {
  center := (aabb.min + aabb.max) * 0.5
  half := (aabb.max - aabb.min) * 0.5
  d := point - center
  best := -max(f32)
  axis := 0
  #unroll for i in 0 ..< 3 {
    s := half[i] > 0 ? math.abs(d[i]) / half[i] : max(f32)
    if s > best {
      best = s
      axis = i
    }
  }
  normal[axis] = d[axis] < 0 ? -1 : 1
  return
}
