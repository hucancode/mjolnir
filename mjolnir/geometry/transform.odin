package geometry

import "core:math/linalg"

// Split an affine matrix into translation, rotation and per-axis scale.
decompose_matrix :: proc "contextless" (
  m: matrix[4, 4]f32,
) -> (
  position: [3]f32,
  rotation: quaternion128,
  scale: [3]f32,
) {
  position = m[3].xyz
  sx := linalg.length(m[0].xyz)
  sy := linalg.length(m[1].xyz)
  sz := linalg.length(m[2].xyz)
  scale = {sx, sy, sz}
  rot_mat := linalg.MATRIX4F32_IDENTITY
  if sx > 0 do rot_mat[0].xyz = m[0].xyz / sx
  if sy > 0 do rot_mat[1].xyz = m[1].xyz / sy
  if sz > 0 do rot_mat[2].xyz = m[2].xyz / sz
  rotation = linalg.to_quaternion(rot_mat)
  return
}
