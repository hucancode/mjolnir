package geometry

import "core:fmt"
import linalg "core:math/linalg"

Transform :: struct {
  position:     linalg.Vector3f32,
  rotation:     linalg.Quaternionf32,
  scale:        linalg.Vector3f32,
  is_dirty:     bool,
  local_matrix: linalg.Matrix4f32,
  world_matrix: linalg.Matrix4f32,
}

transform_identity :: proc() -> Transform {
  return Transform {
    position     = {0, 0, 0},
    rotation     = linalg.QUATERNIONF32_IDENTITY,
    scale        = {1, 1, 1},
    is_dirty     = true, // Mark dirty to force initial matrix calculation
    local_matrix = linalg.MATRIX4F32_IDENTITY,
    world_matrix = linalg.MATRIX4F32_IDENTITY,
  }
}

decompose_matrix :: proc(t: ^Transform, m: linalg.Matrix4f32) {
  // Extract translation
  t.position = {m[0, 3], m[1, 3], m[2, 3]}

  // Extract scale (length of each basis vector)
  sx := linalg.length(linalg.Vector3f32{m[0, 0], m[1, 0], m[2, 0]})
  sy := linalg.length(linalg.Vector3f32{m[0, 1], m[1, 1], m[2, 1]})
  sz := linalg.length(linalg.Vector3f32{m[0, 2], m[1, 2], m[2, 2]})
  t.scale = {sx, sy, sz}

  rot_mat := linalg.MATRIX3F32_IDENTITY
  if sx !=
     0 {rot_mat[0, 0] = m[0, 0] / sx;rot_mat[1, 0] = m[1, 0] / sx;rot_mat[2, 0] = m[2, 0] / sx}
  if sy !=
     0 {rot_mat[0, 1] = m[0, 1] / sy;rot_mat[1, 1] = m[1, 1] / sy;rot_mat[2, 1] = m[2, 1] / sy}
  if sz !=
     0 {rot_mat[0, 2] = m[0, 2] / sz;rot_mat[1, 2] = m[1, 2] / sz;rot_mat[2, 2] = m[2, 2] / sz}

  t.rotation = linalg.quaternion_from_matrix3(rot_mat)
}

matrix_from_slice :: proc(slice: [16]f32) -> linalg.Matrix4f32 {
  ret: linalg.Matrix4f32
  for i in 0 ..< 4 {
    for j in 0 ..< 4 {
      ret[i, j] = slice[j * 4 + i]
    }
  }
  return ret
}
