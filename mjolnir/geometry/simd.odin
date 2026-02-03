package geometry

// Optimize linalg::quaternion128_mul_vector3
qmv :: #force_inline proc "contextless" (q: quaternion128, v: [3]f32) -> [3]f32 {
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

// get x axis of a quaternion, basically linalg::quaternion128_mul_vector3 where input vector is {1, 0, 0}
qx :: #force_inline proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    1 - 2 * (q.y * q.y + q.z * q.z),
    2 * (q.x * q.y + q.w * q.z),
    2 * (q.x * q.z - q.w * q.y),
  }
}

// get y axis of a quaternion, basically linalg::quaternion128_mul_vector3 where input vector is {0, 1, 0}
qy :: #force_inline proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    2 * (q.x * q.y - q.w * q.z),
    1 - 2 * (q.x * q.x + q.z * q.z),
    2 * (q.y * q.z + q.w * q.x),
  }
}

// get z axis of a quaternion, basically linalg::quaternion128_mul_vector3 where input vector is {0, 0, 1}
qz :: #force_inline proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    2 * (q.x * q.z + q.w * q.y),
    2 * (q.y * q.z - q.w * q.x),
    1 - 2 * (q.x * q.x + q.y * q.y),
  }
}
