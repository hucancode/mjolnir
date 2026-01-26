package tests

import "base:intrinsics"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:simd"
import "core:slice"
import "core:testing"
import "core:time"
import "core:thread"
import "core:sync"
import "core:math"
import "base:runtime"

// This test file demonstrates various features of Odin
// It does not test any functionality

// @(test)
test_zero_vs_minus_zero :: proc(t: ^testing.T) {
    a := 0.0
    b := -0.0
    c := -a
    testing.expect_value(t, a, b)
    testing.expect_value(t, a, c)
    testing.expect_value(t, a, c)
    ax := transmute(u64)a
    bx := transmute(u64)b
    testing.expect(t, ax != bx)
    testing.expect_value(t, -linalg.VECTOR3F32_Y_AXIS, [3]f32{0,-1,0})
    T :: struct {
        v: [3]f32,
    }
    actual : T = {
        v = -linalg.VECTOR3F32_Y_AXIS,
    }
    expected : T = {
        v = {0, -1, 0},
    }
    testing.expect_value(t, actual, expected)
}

// @(test)
test_bitset_int_conversion :: proc(t: ^testing.T) {
  Features :: enum {
    SKINNING,
    SHADOWS,
    REFLECTIONS,
  }
  FeatureSet :: bit_set[Features;u32]
  // bit_set to u32
  features := FeatureSet{.SHADOWS, .SKINNING}
  testing.expect_value(t, transmute(u32)features, 0b11)
  // u32 to bit_set
  mask: u32 = 0b11
  testing.expect_value(
    t,
    transmute(FeatureSet)mask,
    FeatureSet{.SHADOWS, .SKINNING},
  )
  testing.expect_value(t, len(Features), 3)
}

// @(test)
dot_product_benchmark :: proc(t: ^testing.T) {
  dot_product_scalar :: proc(a, b: []f32) -> f32 {
    sum: f32 = 0
    for i in 0 ..< len(a) do sum += a[i] * b[i]
    return sum
  }
  dot_product_simd :: proc(a, b: []f32) -> f32 {
    a := a
    b := b
    // some CPU don't support this high, adjust the WIDTH accordingly
    WIDTH :: 64
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
    for i in 0 ..< len(a) do sum += a[i] * b[i]
    return sum
  }
  N :: 10_000_000
  ROUNDS :: 10
  setup :: proc(
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
  }
  teardown :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    delete(options.input)
    return nil
  }
  scalar_opts := &time.Benchmark_Options {
    rounds = ROUNDS,
    bytes = size_of(f32) * N * ROUNDS,
    setup = setup,
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      input_f32 := slice.reinterpret([]f32, options.input)
      a := input_f32[:N]
      b := input_f32[N:]
      for _ in 0 ..< options.rounds {
        _ = dot_product_scalar(a, b)
        options.processed += slice.size(a)
      }
      return nil
    },
    teardown = teardown,
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
    setup = setup,
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      input_f32 := slice.reinterpret([]f32, options.input)
      a := input_f32[:N]
      b := input_f32[N:]
      for _ in 0 ..< options.rounds {
        _ = dot_product_simd(a, b)
        options.processed += slice.size(a)
      }
      return nil
    },
    teardown = teardown,
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

// @(test)
delete_unallocated_slice :: proc(t: ^testing.T) {
  arr: []u32
  delete(arr)
  arr = nil
  delete(arr)
}

// @(test)
err_defer :: proc(t: ^testing.T) {
    job1 :: proc() -> bool {
        return true
    }
    job2 :: proc() -> bool {
        return false
    }
    do_all :: proc() -> (ok: bool) {
        ok = true
        log.info("expecting job 1 clean up to appear!")
        job1() or_return
        defer if !ok do log.info("job 1 clean up")
        job2() or_return
        return
    }
    do_all()
}

// @(test)
loop_through_unallocated_slice :: proc(t: ^testing.T) {
  arr: []u32
  for x in arr do testing.fail_now(t)
  arr = nil
  for x in arr do testing.fail_now(t)
  for i in 1..<len(arr) do testing.fail_now(t)
}

// @(test)
copy_to_unallocated_slice :: proc(t: ^testing.T) {
  src: []u32 = {1, 2, 3}
  dst: []u32
  mem.copy(raw_data(dst), raw_data(src), min(slice.size(src), slice.size(dst)))
  testing.expect_value(t, len(dst), 0)
}

// @(test)
copy_from_unallocated_slice :: proc(t: ^testing.T) {
  src: []u32
  dst: []u32 = {1, 2, 3}
  mem.copy(raw_data(dst), raw_data(src), min(slice.size(src), slice.size(dst)))
  testing.expect_value(t, dst[0], 1)
  testing.expect_value(t, dst[1], 2)
  testing.expect_value(t, dst[2], 3)
}

// @(test)
get_pixel_data :: proc(t: ^testing.T) {
  n := 100
  float_pixels := make([]f32, n)
  defer delete(float_pixels)
  ptr := cast([^]u8)raw_data(float_pixels)
  data := ptr[:n * size_of(f32)]
  testing.expect_value(t, len(data), slice.size(float_pixels))
  data = slice.to_bytes(float_pixels)
  testing.expect_value(t, len(data), slice.size(float_pixels))
}

// @(test)
for_loop_reference_benchmark :: proc(t: ^testing.T) {
  n := 1e3
  options := &time.Benchmark_Options {
    rounds = n,
    bytes = size_of(f32) * 16 * n,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      a := [16]u32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
      arr : [1000][16]u32
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
      for i in 0 ..< options.rounds {
        // for &a in arr do for &x in a do k += (k + x)%1000
        for a in arr do for x in a do k += (k + x) % 1000
        options.processed += size_of([16]u32) * len(arr)
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

// @(test)
test_temp_allocator_real_thread_race_condition :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 3 * time.Second)
    ThreadData :: struct {
        test_t: ^testing.T,
        sum: f32,
    }
    thread_data := ThreadData{
        test_t = t,
    }
    // Thread 1: Allocates 100 floats, waits 1s, then reads them
    t1 := thread.create_and_start_with_poly_data(&thread_data, proc(td: ^ThreadData) {
        data := make([]f32, 100, context.temp_allocator)
        defer free_all(context.temp_allocator)
        slice.fill(data, 1.0)
        log.info("Thread 1: Allocated 100 floats set to 1.0, waiting 0.5 second...")
        time.sleep(500 * time.Millisecond)
        sum := slice.reduce(data, f32(0.0), proc(acc:f32, x:f32) -> f32 {
            return acc + x
        })
        td.sum = sum
    })
    defer free(t1)
    // Thread 2: Allocates 100 floats, waits 0.5s, then frees all
    t2 := thread.create_and_start_with_poly_data(&thread_data, proc(td: ^ThreadData) {
        data := make([]f32, 100, context.temp_allocator)
        defer free_all(context.temp_allocator)
        slice.fill(data, 2.0)
        log.info("Thread 2: Allocated 100 floats, waiting 0.2 seconds...")
        time.sleep(200 * time.Millisecond)
    })
    defer free(t2)
    log.info("Waiting for both threads...")
    thread.join_multiple(t1, t2)
    testing.expectf(t, math.abs(thread_data.sum - 100.0) < math.F32_EPSILON,
        "sum (%v) must be 100.0, release data in 1 thread must not affect the other",
        thread_data.sum)
}

// @(test)
test_temp_allocator_overflow :: proc(t: ^testing.T) {
    data1 := make([]u8, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.temp_allocator)
    testing.expect(t, data1 != nil, "First allocation should succeed")
    slice.fill(data1, 0xAA)
    data2 := make([]u8, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.temp_allocator)
    testing.expect(t, data2 != nil, "Second allocation should succeed")
    slice.fill(data2, 0x55)
    all_aa := slice.all_of(data1, 0xAA)
    testing.expect(t, all_aa, "First allocation should still contain 0xAA pattern")
    all_55 := slice.all_of(data2, 0x55)
    testing.expect(t, all_55, "Second allocation should contain 0x55 pattern")
    free_all(context.temp_allocator)
}
