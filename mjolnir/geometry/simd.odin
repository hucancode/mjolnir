package geometry

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:simd"
import "core:sys/info"

SIMD_Mode :: enum {
  Scalar,
  SSE, // 4-wide (128-bit)
  AVX2, // 8-wide (256-bit)
}

simd_mode: SIMD_Mode
simd_lanes: int

f32x4 :: #simd[4]f32
f32x8 :: #simd[8]f32

// SIMD constants
SIMD_ONE_4 := f32x4{1, 1, 1, 1}
SIMD_TWO_4 := f32x4{2, 2, 2, 2}
SIMD_ONE_8 := f32x8{1, 1, 1, 1, 1, 1, 1, 1}
SIMD_TWO_8 := f32x8{2, 2, 2, 2, 2, 2, 2, 2}

@(init, private)
init_simd :: proc "contextless" () {
  when ODIN_ARCH == .amd64 {
    features := info.cpu_features()
    if .avx2 in features && .fma in features {
      simd_mode = .AVX2
      simd_lanes = 8
      return
    }
    if .sse2 in features {
      simd_mode = .SSE
      simd_lanes = 4
      return
    }
  }
  // Fallback to scalar
  simd_mode = .Scalar
  simd_lanes = 1
}

// Batch AABB intersection test using SIMD (SSE - 4-wide)
// Tests 4 pairs of AABBs simultaneously: result[i] = aabb_intersects(a[i], b[i])
aabb_intersects_batch4 :: proc "contextless" (
  a: [4]Aabb,
  b: [4]Aabb,
) -> [4]bool {
  result: [4]bool

  if simd_mode == .Scalar {
    // Scalar fallback
    result[0] = aabb_intersects(a[0], b[0])
    result[1] = aabb_intersects(a[1], b[1])
    result[2] = aabb_intersects(a[2], b[2])
    result[3] = aabb_intersects(a[3], b[3])
    return result
  }

  // Load AABB components (transpose from AoS to SoA)
  a_min_x := f32x4{a[0].min.x, a[1].min.x, a[2].min.x, a[3].min.x}
  a_min_y := f32x4{a[0].min.y, a[1].min.y, a[2].min.y, a[3].min.y}
  a_min_z := f32x4{a[0].min.z, a[1].min.z, a[2].min.z, a[3].min.z}

  a_max_x := f32x4{a[0].max.x, a[1].max.x, a[2].max.x, a[3].max.x}
  a_max_y := f32x4{a[0].max.y, a[1].max.y, a[2].max.y, a[3].max.y}
  a_max_z := f32x4{a[0].max.z, a[1].max.z, a[2].max.z, a[3].max.z}

  b_min_x := f32x4{b[0].min.x, b[1].min.x, b[2].min.x, b[3].min.x}
  b_min_y := f32x4{b[0].min.y, b[1].min.y, b[2].min.y, b[3].min.y}
  b_min_z := f32x4{b[0].min.z, b[1].min.z, b[2].min.z, b[3].min.z}

  b_max_x := f32x4{b[0].max.x, b[1].max.x, b[2].max.x, b[3].max.x}
  b_max_y := f32x4{b[0].max.y, b[1].max.y, b[2].max.y, b[3].max.y}
  b_max_z := f32x4{b[0].max.z, b[1].max.z, b[2].max.z, b[3].max.z}

  // Perform intersection tests in parallel
  // AABBs intersect if they overlap on all three axes

  // X-axis overlap test
  x_le := simd.lanes_le(a_min_x, b_max_x)
  x_ge := simd.lanes_ge(a_max_x, b_min_x)
  x_overlap := x_le & x_ge

  // Y-axis overlap test
  y_le := simd.lanes_le(a_min_y, b_max_y)
  y_ge := simd.lanes_ge(a_max_y, b_min_y)
  y_overlap := y_le & y_ge

  // Z-axis overlap test
  z_le := simd.lanes_le(a_min_z, b_max_z)
  z_ge := simd.lanes_ge(a_max_z, b_min_z)
  z_overlap := z_le & z_ge

  // Combine all axis tests
  intersects := x_overlap & y_overlap & z_overlap

  // Extract boolean results
  intersects_arr := transmute([4]u32)intersects
  result[0] = intersects_arr[0] != 0
  result[1] = intersects_arr[1] != 0
  result[2] = intersects_arr[2] != 0
  result[3] = intersects_arr[3] != 0

  return result
}

// Optimize linalg::quaternion128_mul_vector3
qmv :: proc "contextless" (q: quaternion128, v: [3]f32) -> [3]f32 {
  // v' = v + 2*(qw*(qv x v) + qv x (qv x v))
  // s = qv x v
  sx := q.y * v.z - q.z * v.y
  sy := q.z * v.x - q.x * v.z
  sz := q.x * v.y - q.y * v.x
  // a = qw*s + qv x s  (FMA-friendly: fma(qw, s, cross))
  ax := q.w * sx + (q.y * sz - q.z * sy)
  ay := q.w * sy + (q.z * sx - q.x * sz)
  az := q.w * sz + (q.x * sy - q.y * sx)
  // v' = v + 2*a  (FMA-friendly: fma(2, a, v))
  return {2 * ax + v.x, 2 * ay + v.y, 2 * az + v.z}
}

// get x axis of a quaternion, basically linalg::quaternion128_mul_vector3 where input vector is {1, 0, 0}
qx :: proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    1 - 2 * (q.y * q.y + q.z * q.z),
    2 * (q.x * q.y + q.w * q.z),
    2 * (q.x * q.z - q.w * q.y),
  }
}

// get y axis of a quaternion, basically linalg::quaternion128_mul_vector3 where input vector is {0, 1, 0}
qy :: proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    2 * (q.x * q.y - q.w * q.z),
    1 - 2 * (q.x * q.x + q.z * q.z),
    2 * (q.y * q.z + q.w * q.x),
  }
}

// get z axis of a quaternion, basically linalg::quaternion128_mul_vector3 where input vector is {0, 0, 1}
qz :: proc "contextless" (q: quaternion128) -> [3]f32 {
  return {
    2 * (q.x * q.z + q.w * q.y),
    2 * (q.y * q.z - q.w * q.x),
    1 - 2 * (q.x * q.x + q.y * q.y),
  }
}
