package tests

import "core:log"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
get_pixel_data :: proc(t: ^testing.T) {
  n := 100
  float_pixels := make([]f32, n)
  defer delete(float_pixels)
  ptr := cast([^]u8)raw_data(float_pixels)
  data := ptr[:n * size_of(f32)]
  testing.expect_value(t, len(data), len(float_pixels) * size_of(f32))
  data = slice.to_bytes(float_pixels)
  testing.expect_value(t, len(data), len(float_pixels) * size_of(f32))
}

@(test)
for_loop_reference_benchmark :: proc(t: ^testing.T) {
  n := 1e9
  options := &time.Benchmark_Options {
    rounds = n,
    bytes = size_of(f32) * 16 * n,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      a := [16]u32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
      arr := [1000][16]u32{}
      slice.fill(arr[:], a)
      options.input = slice.to_bytes(arr[:])
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      arr := slice.to_type(options.input, [1000][16]u32)
      k: u32
      // same result for both case, there is no copy involved when loop by value or loop by reference
      // for a in arr do for x in a do k += (k + x)%1000
      // for &a in arr do for x in a do k += (k + x)%1000
      for a in arr do for x in a do k += (k + x) % 1000
      options.processed += size_of([16]u32) * len(arr)
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
