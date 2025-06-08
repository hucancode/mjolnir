package tests

import "base:intrinsics"
import "core:log"
import "core:simd"
import "core:slice"
import "core:testing"
import "core:time"

dot_product_scalar :: proc(a, b: []f32) -> f32 {
  sum: f32 = 0
  for i in 0 ..< len(a) {
    sum += a[i] * b[i]
  }
  return sum
}

dot_product_simd :: proc(a, b: []f32) -> f32 {
  a := a
  b := b
  WIDTH :: 16
  count := len(a) / WIDTH
  sum_v: #simd[WIDTH]f32
  for i in 0 ..< count {
    chunk_a_ptr := cast(^#simd[WIDTH]f32)raw_data(a[WIDTH:])
    chunk_b_ptr := cast(^#simd[WIDTH]f32)raw_data(b[WIDTH:])
    chunk_a := intrinsics.unaligned_load(chunk_a_ptr)
    chunk_b := intrinsics.unaligned_load(chunk_b_ptr)
    sum_v += chunk_a * chunk_b
    a = a[WIDTH:]
    b = b[WIDTH:]
  }
  sum := simd.reduce_add_ordered(sum_v)
  for i in 0 ..< len(a) {
    sum += a[i] * b[i]
  }
  return sum
}

@(test)
dot_product_benchmark :: proc(t: ^testing.T) {
  N :: 10_000_000
  ROUNDS :: 10
  scalar_opts := &time.Benchmark_Options {
    rounds = ROUNDS,
    bytes = size_of(f32) * N * ROUNDS,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := make([]f32, N * 2)
      for i in 0 ..< N {
        data[i] = f32(i)
        data[i + N] = f32(N - i)
      }
      options.input = slice.to_bytes(data)
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      input_f32 := slice.reinterpret([]f32, options.input)
      a := input_f32[:N]
      b := input_f32[N:]
      for _ in 0 ..< options.rounds {
        _ = dot_product_scalar(a, b)
        options.processed += size_of(f32) * len(a)
      }
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      delete(options.input)
      return nil
    },
  }
  _ = time.benchmark(scalar_opts)
  log.infof(
    "[SCALAR] Time: %v  Speed: %.2f MB/s",
    scalar_opts.duration,
    scalar_opts.megabytes_per_second,
  )
  simd_opts := &time.Benchmark_Options {
    rounds = ROUNDS,
    bytes = size_of(f32) * N * ROUNDS,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := make([]f32, N * 2)
      for i in 0 ..< N {
        data[i] = f32(i)
        data[i + N] = f32(N - i)
      }
      options.input = slice.to_bytes(data)
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      input_f32 := slice.reinterpret([]f32, options.input)
      a := input_f32[:N]
      b := input_f32[N:]
      for _ in 0 ..< options.rounds {
        _ = dot_product_simd(a, b)
        options.processed += size_of(f32) * len(a)
      }
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      delete(options.input)
      return nil
    },
  }
  _ = time.benchmark(simd_opts)
  log.infof(
    "[SIMD] Time: %v  Speed: %.2f MB/s",
    simd_opts.duration,
    simd_opts.megabytes_per_second,
  )
  log.infof(
    "SIMD speed up %.2f%%",
    simd_opts.megabytes_per_second / scalar_opts.megabytes_per_second * 100,
  )
}
