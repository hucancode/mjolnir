package tests

import "../mjolnir/geometry"
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

@(test)
matrix_from_array :: proc(t: ^testing.T) {
  a := [16]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
  m := geometry.matrix_from_arr(a)
  testing.expect(
    t,
    m[0] == {1, 2, 3, 4} &&
    m[1] == {5, 6, 7, 8} &&
    m[2] == {9, 10, 11, 12} &&
    m[3] == {13, 14, 15, 16},
  )
}

@(test)
matrix_from_array_benchmark :: proc(t: ^testing.T) {
  n := 100_000_000
  a := [16]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
  m: linalg.Matrix4f32
  for i in 0 ..< n {
    m = geometry.matrix_from_arr(a)
  }
  testing.expect(
    t,
    m[0] == {1, 2, 3, 4} &&
    m[1] == {5, 6, 7, 8} &&
    m[2] == {9, 10, 11, 12} &&
    m[3] == {13, 14, 15, 16},
  )
}
