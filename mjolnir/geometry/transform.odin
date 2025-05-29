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

TRANSFORM_IDENTITY :: Transform {
  position     = {0, 0, 0},
  rotation     = linalg.QUATERNIONF32_IDENTITY,
  scale        = {1, 1, 1},
  is_dirty     = false,
  local_matrix = linalg.MATRIX4F32_IDENTITY,
  world_matrix = linalg.MATRIX4F32_IDENTITY,
}

decompose_matrix :: proc(t: ^Transform, m: linalg.Matrix4f32) {
  // Extract translation (last column of the matrix)
  t.position = m[3].xyz
  // Extract scale (length of each basis vector)
  t.scale = {linalg.length(m[0]), linalg.length(m[1]), linalg.length(m[2])}
  // Extract rotation (basis vectors normalized)
  t.rotation = linalg.quaternion_from_matrix4(m)
}

matrix_from_arr :: proc(a: [16]f32) -> (m: linalg.Matrix4f32) {
  m[0, 0], m[1, 0], m[2, 0], m[3, 0] = a[0], a[1], a[2], a[3]
  m[0, 1], m[1, 1], m[2, 1], m[3, 1] = a[4], a[5], a[6], a[7]
  m[0, 2], m[1, 2], m[2, 2], m[3, 2] = a[8], a[9], a[10], a[11]
  m[0, 3], m[1, 3], m[2, 3], m[3, 3] = a[12], a[13], a[14], a[15]
  /*
  // about 10 times slower than the above
  for i in 0..<4 {
      for j in 0..<4 {
          m[i, j] = a[j * 4 + i]
      }
  }
  */
  return
}
