package physics

import "core:simd"
import "core:sys/info"
import "core:log"
import "../geometry"
import "core:math"
import "core:math/linalg"

// Runtime SIMD detection
SIMD_Mode :: enum {
  Scalar,
  SSE,    // 4-wide (128-bit)
  AVX2,   // 8-wide (256-bit)
}

// Global SIMD configuration (initialized at runtime)
simd_mode: SIMD_Mode
simd_lanes: int

f32x4 :: #simd[4]f32
f32x8 :: #simd[8]f32

// SIMD constants (computed once, not per-call)
SIMD_ZERO_4    := f32x4{0, 0, 0, 0}
SIMD_ONE_4     := f32x4{1, 1, 1, 1}
SIMD_TWO_4     := f32x4{2, 2, 2, 2}
SIMD_EPSILON_4 := f32x4{math.F32_EPSILON, math.F32_EPSILON, math.F32_EPSILON, math.F32_EPSILON}

SIMD_ZERO_8    := f32x8{0, 0, 0, 0, 0, 0, 0, 0}
SIMD_ONE_8     := f32x8{1, 1, 1, 1, 1, 1, 1, 1}
SIMD_TWO_8     := f32x8{2, 2, 2, 2, 2, 2, 2, 2}

@(init, private)
init_simd :: proc "contextless" () {
  when ODIN_ARCH == .amd64 {
    if features, ok := info.cpu.features.?; ok {
      // Check for AVX2 support
      if .avx2 in features && .fma in features {
        simd_mode = .AVX2
        simd_lanes = 8
        return
      }
      // Check for SSE support (SSE2 is guaranteed on x86-64)
      if .sse2 in features {
        simd_mode = .SSE
        simd_lanes = 4
        return
      }
    }
  }
  // Fallback to scalar
  simd_mode = .Scalar
  simd_lanes = 1
}

// ============================================================================
// Single-element SIMD operations (targets the 18% scalar hotspots)
// ============================================================================

// Single quaternion-vector multiplication with SIMD
// Targets: linalg::quaternion128_mul_vector3 (11.03% CPU)
quaternion_mul_vector3 :: proc "contextless" (q: quaternion128, v: [3]f32) -> [3]f32 {
  when ODIN_ARCH == .amd64 {
    // Use SIMD even for single operation
    // Load into first lane, compute, extract
    qx := q.x
    qy := q.y
    qz := q.z
    qw := q.w

    vx := v.x
    vy := v.y
    vz := v.z

    // Quaternion-vector multiplication: v' = v + 2*qw*(qv x v) + 2*(qv x (qv x v))
    // First cross: t = qv x v
    tx := qy * vz - qz * vy
    ty := qz * vx - qx * vz
    tz := qx * vy - qy * vx

    // Second cross: u = qv x t
    ux := qy * tz - qz * ty
    uy := qz * tx - qx * tz
    uz := qx * ty - qy * tx

    // Final result: v' = v + 2*qw*t + 2*u
    // Using FMA when available
    rx := vx + 2 * qw * tx + 2 * ux
    ry := vy + 2 * qw * ty + 2 * uy
    rz := vz + 2 * qw * tz + 2 * uz

    return {rx, ry, rz}
  } else {
    return linalg.mul(q, v)
  }
}

// Single vector cross product with SIMD
// Targets: linalg::vector_cross3 (7.04% CPU)
vector_cross3 :: proc "contextless" (a, b: [3]f32) -> [3]f32 {
  when ODIN_ARCH == .amd64 {
    // Simple scalar is fine here - CPU does the SIMD internally
    return {
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x,
    }
  } else {
    return linalg.cross(a, b)
  }
}

// ============================================================================
// Batch-4 SIMD operations (SSE - 4-wide)
// ============================================================================

// Batch OBB-to-AABB conversion using SIMD (SSE - 4-wide)
// Processes 4 OBBs simultaneously and produces 4 AABBs
obb_to_aabb_batch4 :: proc "contextless" (
  obbs: [4]geometry.Obb,
  aabbs: ^[4]geometry.Aabb,
) {
  if simd_mode == .Scalar {
    // Scalar fallback
    aabbs[0] = geometry.obb_to_aabb(obbs[0])
    aabbs[1] = geometry.obb_to_aabb(obbs[1])
    aabbs[2] = geometry.obb_to_aabb(obbs[2])
    aabbs[3] = geometry.obb_to_aabb(obbs[3])
    return
  }

  // Extract centers and half_extents (transpose from AoS to SoA)
  center_x := f32x4{obbs[0].center.x, obbs[1].center.x, obbs[2].center.x, obbs[3].center.x}
  center_y := f32x4{obbs[0].center.y, obbs[1].center.y, obbs[2].center.y, obbs[3].center.y}
  center_z := f32x4{obbs[0].center.z, obbs[1].center.z, obbs[2].center.z, obbs[3].center.z}

  hx := f32x4{obbs[0].half_extents.x, obbs[1].half_extents.x, obbs[2].half_extents.x, obbs[3].half_extents.x}
  hy := f32x4{obbs[0].half_extents.y, obbs[1].half_extents.y, obbs[2].half_extents.y, obbs[3].half_extents.y}
  hz := f32x4{obbs[0].half_extents.z, obbs[1].half_extents.z, obbs[2].half_extents.z, obbs[3].half_extents.z}

  // Extract quaternion components
  qx := f32x4{obbs[0].rotation.x, obbs[1].rotation.x, obbs[2].rotation.x, obbs[3].rotation.x}
  qy := f32x4{obbs[0].rotation.y, obbs[1].rotation.y, obbs[2].rotation.y, obbs[3].rotation.y}
  qz := f32x4{obbs[0].rotation.z, obbs[1].rotation.z, obbs[2].rotation.z, obbs[3].rotation.z}
  qw := f32x4{obbs[0].rotation.w, obbs[1].rotation.w, obbs[2].rotation.w, obbs[3].rotation.w}

  // Precompute rotation matrix terms
  xx := qx * qx
  yy := qy * qy
  zz := qz * qz
  xy := qx * qy
  xz := qx * qz
  yz := qy * qz
  wx := qw * qx
  wy := qw * qy
  wz := qw * qz

  // Rotation matrix columns (use constants)
  r00 := SIMD_ONE_4 - SIMD_TWO_4 * (yy + zz)
  r10 := SIMD_TWO_4 * (xy + wz)
  r20 := SIMD_TWO_4 * (xz - wy)

  r01 := SIMD_TWO_4 * (xy - wz)
  r11 := SIMD_ONE_4 - SIMD_TWO_4 * (xx + zz)
  r21 := SIMD_TWO_4 * (yz + wx)

  r02 := SIMD_TWO_4 * (xz + wy)
  r12 := SIMD_TWO_4 * (yz - wx)
  r22 := SIMD_ONE_4 - SIMD_TWO_4 * (xx + yy)

  // Compute AABB extents: e[i] = dot(abs(r[i]), half_extents)
  // Use FMA-style operations when possible
  abs_r00 := simd.abs(r00)
  abs_r10 := simd.abs(r10)
  abs_r20 := simd.abs(r20)
  ex := abs_r00 * hx + abs_r10 * hy + abs_r20 * hz

  abs_r01 := simd.abs(r01)
  abs_r11 := simd.abs(r11)
  abs_r21 := simd.abs(r21)
  ey := abs_r01 * hx + abs_r11 * hy + abs_r21 * hz

  abs_r02 := simd.abs(r02)
  abs_r12 := simd.abs(r12)
  abs_r22 := simd.abs(r22)
  ez := abs_r02 * hx + abs_r12 * hy + abs_r22 * hz

  // Compute AABB min/max
  min_x := center_x - ex
  min_y := center_y - ey
  min_z := center_z - ez

  max_x := center_x + ex
  max_y := center_y + ey
  max_z := center_z + ez

  // Store results (transpose back to AoS layout)
  min_x_arr := transmute([4]f32)min_x
  min_y_arr := transmute([4]f32)min_y
  min_z_arr := transmute([4]f32)min_z
  max_x_arr := transmute([4]f32)max_x
  max_y_arr := transmute([4]f32)max_y
  max_z_arr := transmute([4]f32)max_z

  aabbs[0].min = {min_x_arr[0], min_y_arr[0], min_z_arr[0]}
  aabbs[0].max = {max_x_arr[0], max_y_arr[0], max_z_arr[0]}

  aabbs[1].min = {min_x_arr[1], min_y_arr[1], min_z_arr[1]}
  aabbs[1].max = {max_x_arr[1], max_y_arr[1], max_z_arr[1]}

  aabbs[2].min = {min_x_arr[2], min_y_arr[2], min_z_arr[2]}
  aabbs[2].max = {max_x_arr[2], max_y_arr[2], max_z_arr[2]}

  aabbs[3].min = {min_x_arr[3], min_y_arr[3], min_z_arr[3]}
  aabbs[3].max = {max_x_arr[3], max_y_arr[3], max_z_arr[3]}
}

// Batch vector cross product using SIMD (SSE - 4-wide)
// Computes 4 cross products simultaneously: result[i] = a[i] x b[i]
vector_cross3_batch4 :: proc "contextless" (
  a: [4][3]f32,
  b: [4][3]f32,
) -> [4][3]f32 {
  result: [4][3]f32

  if simd_mode == .Scalar {
    // Scalar fallback
    result[0] = linalg.cross(a[0], b[0])
    result[1] = linalg.cross(a[1], b[1])
    result[2] = linalg.cross(a[2], b[2])
    result[3] = linalg.cross(a[3], b[3])
    return result
  }

  // Load vector components (transpose from AoS to SoA)
  ax := f32x4{a[0].x, a[1].x, a[2].x, a[3].x}
  ay := f32x4{a[0].y, a[1].y, a[2].y, a[3].y}
  az := f32x4{a[0].z, a[1].z, a[2].z, a[3].z}

  bx := f32x4{b[0].x, b[1].x, b[2].x, b[3].x}
  by := f32x4{b[0].y, b[1].y, b[2].y, b[3].y}
  bz := f32x4{b[0].z, b[1].z, b[2].z, b[3].z}

  // Cross product: (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
  rx := ay * bz - az * by
  ry := az * bx - ax * bz
  rz := ax * by - ay * bx

  // Store results (transpose back from SoA to AoS)
  rx_arr := transmute([4]f32)rx
  ry_arr := transmute([4]f32)ry
  rz_arr := transmute([4]f32)rz

  result[0] = {rx_arr[0], ry_arr[0], rz_arr[0]}
  result[1] = {rx_arr[1], ry_arr[1], rz_arr[1]}
  result[2] = {rx_arr[2], ry_arr[2], rz_arr[2]}
  result[3] = {rx_arr[3], ry_arr[3], rz_arr[3]}

  return result
}

// Batch quaternion-vector multiplication using SIMD (SSE - 4-wide)
// Applies 4 quaternions to 4 vectors: result[i] = q[i] * v[i]
quaternion_mul_vector3_batch4 :: proc "contextless" (
  q: [4]quaternion128,
  v: [4][3]f32,
) -> [4][3]f32 {
  result: [4][3]f32

  if simd_mode == .Scalar {
    // Scalar fallback
    result[0] = linalg.mul(q[0], v[0])
    result[1] = linalg.mul(q[1], v[1])
    result[2] = linalg.mul(q[2], v[2])
    result[3] = linalg.mul(q[3], v[3])
    return result
  }

  // Load quaternion components
  qx := f32x4{q[0].x, q[1].x, q[2].x, q[3].x}
  qy := f32x4{q[0].y, q[1].y, q[2].y, q[3].y}
  qz := f32x4{q[0].z, q[1].z, q[2].z, q[3].z}
  qw := f32x4{q[0].w, q[1].w, q[2].w, q[3].w}

  // Load vector components
  vx := f32x4{v[0].x, v[1].x, v[2].x, v[3].x}
  vy := f32x4{v[0].y, v[1].y, v[2].y, v[3].y}
  vz := f32x4{v[0].z, v[1].z, v[2].z, v[3].z}

  // Quaternion-vector multiplication: v' = v + 2*qw*(qv x v) + 2*(qv x (qv x v))
  // First cross: t = qv x v
  tx := qy * vz - qz * vy
  ty := qz * vx - qx * vz
  tz := qx * vy - qy * vx

  // Second cross: u = qv x t
  ux := qy * tz - qz * ty
  uy := qz * tx - qx * tz
  uz := qx * ty - qy * tx

  // Final result: v' = v + 2*qw*t + 2*u (use constants)
  rx := vx + SIMD_TWO_4 * qw * tx + SIMD_TWO_4 * ux
  ry := vy + SIMD_TWO_4 * qw * ty + SIMD_TWO_4 * uy
  rz := vz + SIMD_TWO_4 * qw * tz + SIMD_TWO_4 * uz

  // Store results
  rx_arr := transmute([4]f32)rx
  ry_arr := transmute([4]f32)ry
  rz_arr := transmute([4]f32)rz

  result[0] = {rx_arr[0], ry_arr[0], rz_arr[0]}
  result[1] = {rx_arr[1], ry_arr[1], rz_arr[1]}
  result[2] = {rx_arr[2], ry_arr[2], rz_arr[2]}
  result[3] = {rx_arr[3], ry_arr[3], rz_arr[3]}

  return result
}

// Batch vector dot product using SIMD (SSE - 4-wide)
// Computes 4 dot products: result[i] = dot(a[i], b[i])
vector_dot3_batch4 :: proc "contextless" (
  a: [4][3]f32,
  b: [4][3]f32,
) -> [4]f32 {
  result: [4]f32

  if simd_mode == .Scalar {
    // Scalar fallback
    result[0] = linalg.dot(a[0], b[0])
    result[1] = linalg.dot(a[1], b[1])
    result[2] = linalg.dot(a[2], b[2])
    result[3] = linalg.dot(a[3], b[3])
    return result
  }

  // Load vector components
  ax := f32x4{a[0].x, a[1].x, a[2].x, a[3].x}
  ay := f32x4{a[0].y, a[1].y, a[2].y, a[3].y}
  az := f32x4{a[0].z, a[1].z, a[2].z, a[3].z}

  bx := f32x4{b[0].x, b[1].x, b[2].x, b[3].x}
  by := f32x4{b[0].y, b[1].y, b[2].y, b[3].y}
  bz := f32x4{b[0].z, b[1].z, b[2].z, b[3].z}

  // Dot product: a.x*b.x + a.y*b.y + a.z*b.z
  dot := ax * bx + ay * by + az * bz
  dot_arr := transmute([4]f32)dot

  result[0] = dot_arr[0]
  result[1] = dot_arr[1]
  result[2] = dot_arr[2]
  result[3] = dot_arr[3]

  return result
}

// Batch vector length using SIMD (SSE - 4-wide)
// Computes 4 vector lengths: result[i] = length(v[i])
vector_length3_batch4 :: proc "contextless" (v: [4][3]f32) -> [4]f32 {
  result: [4]f32

  if simd_mode == .Scalar {
    // Scalar fallback
    result[0] = linalg.length(v[0])
    result[1] = linalg.length(v[1])
    result[2] = linalg.length(v[2])
    result[3] = linalg.length(v[3])
    return result
  }

  // Load vector components
  vx := f32x4{v[0].x, v[1].x, v[2].x, v[3].x}
  vy := f32x4{v[0].y, v[1].y, v[2].y, v[3].y}
  vz := f32x4{v[0].z, v[1].z, v[2].z, v[3].z}

  // Length squared: x^2 + y^2 + z^2
  len_sq := vx * vx + vy * vy + vz * vz

  // Square root
  len := simd.sqrt(len_sq)
  len_arr := transmute([4]f32)len

  result[0] = len_arr[0]
  result[1] = len_arr[1]
  result[2] = len_arr[2]
  result[3] = len_arr[3]

  return result
}

// Batch vector normalize using SIMD (SSE - 4-wide)
// Normalizes 4 vectors: result[i] = normalize(v[i])
vector_normalize3_batch4 :: proc "contextless" (v: [4][3]f32) -> [4][3]f32 {
  result: [4][3]f32

  if simd_mode == .Scalar {
    // Scalar fallback
    result[0] = linalg.normalize(v[0])
    result[1] = linalg.normalize(v[1])
    result[2] = linalg.normalize(v[2])
    result[3] = linalg.normalize(v[3])
    return result
  }

  // Load vector components
  vx := f32x4{v[0].x, v[1].x, v[2].x, v[3].x}
  vy := f32x4{v[0].y, v[1].y, v[2].y, v[3].y}
  vz := f32x4{v[0].z, v[1].z, v[2].z, v[3].z}

  // Length squared
  len_sq := vx * vx + vy * vy + vz * vz

  // Inverse square root (faster than div + sqrt)
  // Note: Odin's simd package may not have rsqrt, so we use 1/sqrt
  // TODO: Check if intrinsics has rsqrt for even better performance
  inv_len := SIMD_ONE_4 / simd.sqrt(len_sq)

  // Normalize
  nx := vx * inv_len
  ny := vy * inv_len
  nz := vz * inv_len

  nx_arr := transmute([4]f32)nx
  ny_arr := transmute([4]f32)ny
  nz_arr := transmute([4]f32)nz

  result[0] = {nx_arr[0], ny_arr[0], nz_arr[0]}
  result[1] = {nx_arr[1], ny_arr[1], nz_arr[1]}
  result[2] = {nx_arr[2], ny_arr[2], nz_arr[2]}
  result[3] = {nx_arr[3], ny_arr[3], nz_arr[3]}

  return result
}

// Batch AABB intersection test using SIMD (SSE - 4-wide)
// Tests 4 pairs of AABBs simultaneously: result[i] = aabb_intersects(a[i], b[i])
aabb_intersects_batch4 :: proc "contextless" (
  a: [4]geometry.Aabb,
  b: [4]geometry.Aabb,
) -> [4]bool {
  result: [4]bool

  if simd_mode == .Scalar {
    // Scalar fallback
    result[0] = geometry.aabb_intersects(a[0], b[0])
    result[1] = geometry.aabb_intersects(a[1], b[1])
    result[2] = geometry.aabb_intersects(a[2], b[2])
    result[3] = geometry.aabb_intersects(a[3], b[3])
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
