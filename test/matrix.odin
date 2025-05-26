package tests

import "../mjolnir/geometry"
import "core:fmt"
import "core:log"
import linalg "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
matrix_multiply_vector :: proc(t: ^testing.T) {
  v := [4]f32{0, 0, 0, 1}
  m := linalg.matrix4_translate_f32({1, 2, 3})
  testing.expect_value(t, m * v, linalg.Vector4f32{1, 2, 3, 1})
}

@(test)
matrix_extract_decompose :: proc(t: ^testing.T) {
  translation := [4]f32{1, 2, 3, 1}
  m := linalg.matrix4_translate_f32({1, 2, 3})
  testing.expect_value(t, m[3], translation)
  m = linalg.matrix4_scale_f32({2, 3, 4})
  sx := linalg.length(m[0])
  sy := linalg.length(m[1])
  sz := linalg.length(m[2])
  testing.expect_value(t, sx, 2)
  testing.expect_value(t, sy, 3)
  testing.expect_value(t, sz, 4)
}

@(test)
matrix_from_array :: proc(t: ^testing.T) {
  a := [16]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
  m := geometry.matrix_from_arr(a)
  testing.expect_value(t, m[0], [4]f32{1, 2, 3, 4})
  testing.expect_value(t, m[1], [4]f32{5, 6, 7, 8})
  testing.expect_value(t, m[2], [4]f32{9, 10, 11, 12})
  testing.expect_value(t, m[3], [4]f32{13, 14, 15, 16})
}

@(test)
matrix_from_array_benchmark :: proc(t: ^testing.T) {
  n := 1e7
  options := &time.Benchmark_Options {
    rounds = n,
    bytes = size_of(f32) * 16 * n,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      a := [16]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
      options.input = slice.to_bytes(a[:])
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      a := slice.to_type(options.input, [16]f32)
      for i in 0 ..< options.rounds {
        _ = geometry.matrix_from_arr(a)
        options.processed += size_of([16]f32)
      }
      return nil
    },
  }
  err := time.benchmark(options)
  log.infof(
    "Benchmark finished in %v, speed: %0.2f MB/s",
    options.duration,
    options.megabytes_per_second,
  )
}
