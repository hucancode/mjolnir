package geometry

import "core:math/linalg"

// Optimize linalg::quaternion128_mul_vector3
qmv :: proc "contextless" (q: quaternion128, v: [3]f32) -> [3]f32 {
  // Quaternion-vector multiplication: v' = v + 2*qw*(qv x v) + 2*(qv x (qv x v))
  // First cross: t = 2(qv x v)
  tx := 2 * (q.y * v.z - q.z * v.y)
  ty := 2 * (q.z * v.x - q.x * v.z)
  tz := 2 * (q.x * v.y - q.y * v.x)
  // Second cross: u = qv x t
  ux := q.y * tz - q.z * ty
  uy := q.z * tx - q.x * tz
  uz := q.x * ty - q.y * tx
  // Final result: v' = v + q.w*t + u
  // Using FMA when available
  rx := v.x + q.w * tx + ux
  ry := v.y + q.w * ty + uy
  rz := v.z + q.w * tz + uz
  return {rx, ry, rz}
}
