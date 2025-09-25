package tests

import "../mjolnir/resources"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"

TestData :: struct {
  value: i32,
  name:  string,
}

@(test)
test_resource_pool_basic_allocation :: proc(t: ^testing.T) {
  pool: resources.Pool(TestData)
  resources.pool_init(&pool)
  defer resources.pool_destroy(pool, proc(data: ^TestData) {})

  handle, data := resources.alloc(&pool)
  testing.expect(t, data != nil)
  testing.expect_value(t, handle.generation, 1)

  data.value = 42
  retrieved := resources.get(pool, handle)
  testing.expect_value(t, retrieved.value, 42)
}

@(test)
test_resource_pool_handle_invalidation :: proc(t: ^testing.T) {
  pool: resources.Pool(TestData)
  resources.pool_init(&pool)
  defer resources.pool_destroy(pool, proc(data: ^TestData) {})

  handle, _ := resources.alloc(&pool)
  resources.free(&pool, handle)

  retrieved, found := resources.get(pool, handle)
  testing.expect(t, !found)
  testing.expect(t, retrieved == nil)
}

@(test)
test_resource_pool_generation_increment :: proc(t: ^testing.T) {
  pool: resources.Pool(TestData)
  resources.pool_init(&pool)
  defer resources.pool_destroy(pool, proc(data: ^TestData) {})
  handle1, _ := resources.alloc(&pool)
  resources.free(&pool, handle1)
  handle2, _ := resources.alloc(&pool)
  testing.expect_value(t, handle2.index, handle1.index) // same index reused
  testing.expect(t, handle2.generation > handle1.generation) // generation incremented
}

@(test)
test_invalid_resource_handles :: proc(t: ^testing.T) {
  pool: resources.Pool(int)
  resources.pool_init(&pool)
  defer resources.pool_destroy(pool, proc(data: ^int) {})
  invalid_handle := resources.Handle {
    index      = 9999,
    generation = 1,
  }
  data, found := resources.get(pool, invalid_handle)
  testing.expect(t, !found)
  testing.expect(t, data == nil)
}

@(test)
benchmark_resource_pool_read :: proc(t: ^testing.T) {
  COUNT :: 100_000
  READ_COUNT :: 100_000
  ResourcePoolTest :: struct {
    pool:    resources.Pool(TestData),
    handles: []resources.Handle,
  }
  resource_pool_opts := &time.Benchmark_Options {
    rounds = 1,
    bytes = int(size_of(TestData)) * READ_COUNT,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := new(ResourcePoolTest)
      data.handles = make([]resources.Handle, READ_COUNT)
      resources.pool_init(&data.pool)
      for i in 0 ..< COUNT {
        handle, d := resources.alloc(&data.pool)
        d.value = rand.int31()
        data.handles[i] = handle
      }
      for &handle in data.handles {
        handle.index = u32(rand.int31() % COUNT)
        handle.generation = 1
      }
      options.input = slice.bytes_from_ptr(data, size_of(^ResourcePoolTest))
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      sum: i32 = 0
      data := cast(^ResourcePoolTest)(raw_data(options.input))
      for h in data.handles {
        d := resources.get(data.pool, h)
        sum += d.value
        options.processed += size_of(TestData)
      }
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := cast(^ResourcePoolTest)(raw_data(options.input))
      resources.pool_destroy(data.pool, proc(data: ^TestData) {})
      delete(data.handles)
      free(data)
      return nil
    },
  }
  SliceTest :: struct {
    pool:    []TestData,
    indices: []int,
  }
  pointer_array_opts := &time.Benchmark_Options {
    rounds = 1,
    bytes = int(size_of(TestData)) * READ_COUNT,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := new(SliceTest)
      data.pool = make([]TestData, COUNT)
      data.indices = make([]int, READ_COUNT)
      for i in 0 ..< COUNT {
        data.pool[i].value = rand.int31()
      }
      for i in 0 ..< READ_COUNT {
        data.indices[i] = int(rand.int31() % COUNT)
      }
      options.input = slice.bytes_from_ptr(data, size_of(^SliceTest))
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      sum: i32 = 0
      data := cast(^SliceTest)(raw_data(options.input))
      for idx in data.indices {
        sum += data.pool[idx].value
        options.processed += size_of(TestData)
      }
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := cast(^SliceTest)(raw_data(options.input))
      delete(data.pool)
      delete(data.indices)
      free(data)
      return nil
    },
  }
  _ = time.benchmark(resource_pool_opts)
  _ = time.benchmark(pointer_array_opts)
  log.infof(
    "[RESOURCE POOL] Time: %v  Speed: %.2f MB/s\n[NORMAL POINTER] Time: %v  Speed: %.2f MB/s\nResource pool slowed down: %.2f%%",
    resource_pool_opts.duration,
    resource_pool_opts.megabytes_per_second,
    pointer_array_opts.duration,
    pointer_array_opts.megabytes_per_second,
    (1.0 -
      resource_pool_opts.megabytes_per_second /
        pointer_array_opts.megabytes_per_second) *
    100,
  )
}

@(test)
benchmark_resource_pool_write :: proc(t: ^testing.T) {
  OP_COUNT :: 100_000
  ResourcePoolTest :: struct {
    pool:       resources.Pool(TestData),
    operations: []bool,
  }
  resource_pool_opts := &time.Benchmark_Options {
    rounds = 1,
    bytes = int(size_of(TestData)) * OP_COUNT,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := new(ResourcePoolTest)
      data.operations = make([]bool, OP_COUNT)
      resources.pool_init(&data.pool)
      for &op in data.operations {
        op = rand.float32() < 0.5
      }
      options.input = slice.bytes_from_ptr(data, size_of(^ResourcePoolTest))
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := cast(^ResourcePoolTest)(raw_data(options.input))
      allocated := make([dynamic]resources.Handle, 0, len(data.operations))
      defer delete(allocated)
      for should_alloc in data.operations {
        if should_alloc {
          handle, d := resources.alloc(&data.pool)
          d.value = rand.int31()
          append(&allocated, handle)
        } else {
          handle, ok := pop_safe(&allocated)
          if ok {
            resources.free(&data.pool, handle)
          }
        }
        options.processed += size_of(TestData)
      }
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := cast(^ResourcePoolTest)(raw_data(options.input))
      resources.pool_destroy(data.pool, proc(data: ^TestData) {})
      delete(data.operations)
      free(data)
      return nil
    },
  }
  SliceTest :: struct {
    operations: []bool,
  }
  pointer_array_opts := &time.Benchmark_Options {
    rounds = 1,
    bytes = int(size_of(TestData)) * OP_COUNT,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := new(SliceTest)
      data.operations = make([]bool, OP_COUNT)
      for &op in data.operations {
        op = rand.float32() < 0.5
      }
      options.input = slice.bytes_from_ptr(data, size_of(^SliceTest))
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := cast(^SliceTest)(raw_data(options.input))
      allocated := make([dynamic]^TestData, 0, len(data.operations))
      defer delete(allocated)
      for should_alloc in data.operations {
        if should_alloc {
          d := new(TestData)
          d.value = rand.int31()
          append(&allocated, d)
        } else {
          d, ok := pop_safe(&allocated)
          if ok {
            free(d)
          }
        }
        options.processed += size_of(TestData)
      }
      for d in allocated do free(d)
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      data := cast(^SliceTest)(raw_data(options.input))
      delete(data.operations)
      free(data)
      return nil
    },
  }
  _ = time.benchmark(resource_pool_opts)
  _ = time.benchmark(pointer_array_opts)
  log.infof(
    "[RESOURCE POOL] Time: %v  Speed: %.2f MB/s\n[NORMAL POINTER] Time: %v  Speed: %.2f MB/s\nResource pool speed up: %.2f%%",
    resource_pool_opts.duration,
    resource_pool_opts.megabytes_per_second,
    pointer_array_opts.duration,
    pointer_array_opts.megabytes_per_second,
    (resource_pool_opts.megabytes_per_second /
      pointer_array_opts.megabytes_per_second) *
    100,
  )
}
