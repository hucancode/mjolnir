package tests

import linalg "core:math/linalg"
import "core:fmt"
import "core:testing"

@(test)
matrix_multiply_vector :: proc(t: ^testing.T) {
    v := [4]f32{0, 0, 0, 1}
    m := linalg.matrix4_translate_f32({1, 2, 3})
    testing.expect(t, m*v == linalg.Vector4f32{1, 2, 3, 1}, "Matrix multiplication failed")
}
