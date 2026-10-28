package geometry

import "core:math/linalg"

// Transform is a position, rotation and per-axis scale: a scene node's or a bone's local
// transform.
Transform :: struct {
  position: [3]f32,
  rotation: quaternion128,
  scale:    [3]f32,
}

// TRANSFORM_IDENTITY is the transform that changes nothing.
TRANSFORM_IDENTITY :: Transform{rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 1, 1}}

// decompose_matrix splits an affine matrix into translation, rotation and per-axis scale.
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

// transform_mul returns child placed in parent's frame: child's transform followed by parent's.
// Exact while parent's scale is uniform or the child is unrotated.
transform_mul :: proc "contextless" (parent, child: Transform) -> Transform {
  return {
    position = transform_point(parent, child.position),
    rotation = parent.rotation * child.rotation,
    scale    = parent.scale * child.scale,
  }
}

// transform_point returns p moved from t's frame into its parent's: scaled, rotated, translated.
transform_point :: proc "contextless" (t: Transform, p: [3]f32) -> [3]f32 {
  return t.position + qmv(t.rotation, t.scale * p)
}
