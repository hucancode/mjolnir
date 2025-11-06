package tests

import "../mjolnir/geometry"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

matrix4_almost_equal :: proc(
  t: ^testing.T,
  actual, expected: matrix[4, 4]f32,
) {
  for i in 0 ..< 4 {
    for j in 0 ..< 4 {
      delta := math.abs(actual[i, j] - expected[i, j])
      // Use a more lenient epsilon for floating point comparisons
      testing.expect(
        t,
        delta < 0.01,
        fmt.tprintf("Matrix difference at [%d,%d]: %f", i, j, delta),
      )
    }
  }
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
  n := 1e6
  options := &time.Benchmark_Options {
    rounds = n,
    bytes = size_of([16]f32) * n,
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
