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
  is_dirty     = true, // Mark dirty to force initial matrix calculation
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

matrix_from_slice :: proc(slice: [16]f32) -> (ret: linalg.Matrix4f32) {
  for i in 0 ..< 4 {
    for j in 0 ..< 4 {
      ret[i, j] = slice[j * 4 + i]
    }
  }
  return ret
}
