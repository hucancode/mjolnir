package geometry

// qmv rotates v by q; a faster linalg.quaternion128_mul_vector3.
qmv :: proc "contextless" (q: quaternion128, v: [3]f32) -> [3]f32 {
  // v' = v + 2*(qw*(qv x v) + qv x (qv x v))
  sx := q.y * v.z - q.z * v.y
  sy := q.z * v.x - q.x * v.z
  sz := q.x * v.y - q.y * v.x
  ax := q.w * sx + (q.y * sz - q.z * sy)
  ay := q.w * sy + (q.z * sx - q.x * sz)
  az := q.w * sz + (q.x * sy - q.y * sx)
  return {2 * ax + v.x, 2 * ay + v.y, 2 * az + v.z}
}

// qx returns q rotating {1, 0, 0}.
qx :: proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    1 - 2 * (q.y * q.y + q.z * q.z),
    2 * (q.x * q.y + q.w * q.z),
    2 * (q.x * q.z - q.w * q.y),
  }
}

// qy returns q rotating {0, 1, 0}.
qy :: proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    2 * (q.x * q.y - q.w * q.z),
    1 - 2 * (q.x * q.x + q.z * q.z),
    2 * (q.y * q.z + q.w * q.x),
  }
}

// qz returns q rotating {0, 0, 1}.
qz :: proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    2 * (q.x * q.z + q.w * q.y),
    2 * (q.y * q.z - q.w * q.x),
    1 - 2 * (q.x * q.x + q.y * q.y),
  }
}
