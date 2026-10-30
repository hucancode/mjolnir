package geometry

import "core:math"
import "core:math/linalg"

// is_identity_quaternion reports whether q is the identity rotation within 1e-6.
is_identity_quaternion :: proc "contextless" (q: quaternion128) -> bool {
  epsilon :: 1e-6
  return(
    math.abs(q.x) < epsilon &&
    math.abs(q.y) < epsilon &&
    math.abs(q.z) < epsilon &&
    math.abs(q.w - 1.0) < epsilon \
  )
}

// skew returns the cross-product matrix of v: skew(a) * b == cross(a, b).
skew :: #force_inline proc "contextless" (v: [3]f32) -> matrix[3, 3]f32 {
  return matrix[3, 3]f32{
    0, -v.z, v.y,
    v.z, 0, -v.x,
    -v.y, v.x, 0,
  }
}

// tangent_basis returns two vectors orthogonal to normal and to each other.
tangent_basis :: proc "contextless" (normal: [3]f32) -> (t1, t2: [3]f32) {
  t1 = linalg.orthogonal(normal)
  t2 = linalg.cross(normal, t1)
  return
}

// aabb_face_normal returns the outward normal of the face of aabb nearest to point, for points on or near the surface.
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

// exp_smooth returns the lerp factor that moves a value toward its target at rate k per second
// over dt, the same whatever the frame rate: x = lerp(x, target, exp_smooth(k, dt)). Easing
// curves are core:math/ease's.
exp_smooth :: proc "contextless" (k, dt: f32) -> f32 {
  return 1 - math.exp(-k * dt)
}
