package tests

import "core:fmt"
import linalg "core:math/linalg"
import "core:testing"

@(test)
matrix_multiply_vector :: proc(t: ^testing.T) {
  v := [4]f32{0, 0, 0, 1}
  m := linalg.matrix4_translate_f32({1, 2, 3})
  testing.expect(t, m * v == linalg.Vector4f32{1, 2, 3, 1})
}

@(test)
matrix_extract_decompose :: proc(t: ^testing.T) {
  translation := [4]f32{1, 2, 3, 1}
  m := linalg.matrix4_translate_f32({1, 2, 3})
  testing.expect(t, m[3] == translation)
  m = linalg.matrix4_scale_f32({2, 3, 4})
  sx := linalg.length(m[0])
  sy := linalg.length(m[1])
  sz := linalg.length(m[2])
  testing.expect(t, sx == 2 && sy == 3 && sz == 4)
}
