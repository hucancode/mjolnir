package geometry

import "core:log"
import "core:math/linalg"

Transform :: struct {
  position:       [3]f32,
  rotation:       quaternion128,
  scale:          [3]f32,
  is_dirty:       bool,   // Local matrix needs recalculation from position/rotation/scale
  local_matrix:   matrix[4,4]f32,
  world_matrix:   matrix[4,4]f32,
}

TRANSFORM_IDENTITY :: Transform {
  position     = {0, 0, 0},
  rotation     = linalg.QUATERNIONF32_IDENTITY,
  scale        = {1, 1, 1},
  is_dirty     = false,
  local_matrix = linalg.MATRIX4F32_IDENTITY,
  world_matrix = linalg.MATRIX4F32_IDENTITY,
}

decompose_matrix :: proc(m: matrix[4,4]f32) -> (ret: Transform) {
  // Extract translation (last column of the matrix)
  ret.position = m[3].xyz
  // Extract scale (length of each basis vector)
  ret.scale = {linalg.length(m[0]), linalg.length(m[1]), linalg.length(m[2])}
  // Extract rotation (basis vectors normalized)
  ret.rotation = linalg.quaternion_from_matrix4(m)
  ret.is_dirty = true
  return
}

matrix_from_arr :: proc(a: [16]f32) -> (m: matrix[4,4]f32) {
  m[0, 0], m[1, 0], m[2, 0], m[3, 0] = a[0], a[1], a[2], a[3]
  m[0, 1], m[1, 1], m[2, 1], m[3, 1] = a[4], a[5], a[6], a[7]
  m[0, 2], m[1, 2], m[2, 2], m[3, 2] = a[8], a[9], a[10], a[11]
  m[0, 3], m[1, 3], m[2, 3], m[3, 3] = a[12], a[13], a[14], a[15]
  /*
  // this code is about 10 times slower than the above
  for i in 0..<4 {
      for j in 0..<4 {
          m[i, j] = a[j * 4 + i]
      }
  }
  */
  return
}

transform_translate_by :: proc(t: ^Transform, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  t.position += {x, y, z}
  t.is_dirty = true
}

transform_translate :: proc(t: ^Transform, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  t.position = {x, y, z}
  t.is_dirty = true
}

transform_rotate_by :: proc {
    transform_rotate_by_quaternion,
    transform_rotate_by_angle,
}

transform_rotate_by_quaternion :: proc(t: ^Transform, q: quaternion128) {
  t.rotation *= q
  t.is_dirty = true
}

transform_rotate_by_angle :: proc(
  t: ^Transform,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  t.rotation *= linalg.quaternion_angle_axis(angle, axis)
  t.is_dirty = true
}

transform_rotate :: proc {
  transform_rotate_quaternion,
  transform_rotate_angle,
}

transform_rotate_quaternion :: proc(t: ^Transform, q: quaternion128) {
  t.rotation = q
  t.is_dirty = true
}

transform_rotate_angle :: proc(
  t: ^Transform,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  t.rotation = linalg.quaternion_angle_axis(angle, axis)
  t.is_dirty = true
}

transform_scale_xyz_by :: proc(t: ^Transform, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  t.scale *= {x, y, z}
  t.is_dirty = true
}

transform_scale_by :: proc(t: ^Transform, s: f32) {
  t.scale *= {s, s, s}
  t.is_dirty = true
}

transform_scale_xyz :: proc(t: ^Transform, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  t.scale = {x, y, z}
  t.is_dirty = true
}

transform_scale :: proc(t: ^Transform, s: f32) {
  t.scale = {s, s, s}
  t.is_dirty = true
}

transform_update_local :: proc(t: ^Transform) -> bool {
  if !t.is_dirty {
    return false
  }
  t.local_matrix = linalg.matrix4_from_trs(t.position, t.rotation, t.scale)
  t.is_dirty = false
  return true
}

// Helper functions for double-buffered world matrix
transform_get_world_matrix :: proc(t: ^Transform) -> matrix[4,4]f32 {
  return t.world_matrix
}

transform_update_world :: proc(
  t: ^Transform,
  parent: matrix[4,4]f32,
) -> bool {
  new_world_matrix := parent * t.local_matrix
  t.world_matrix = new_world_matrix
  t.is_dirty = false
  return true
}
