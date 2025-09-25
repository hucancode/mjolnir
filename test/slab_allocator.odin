package tests

import "../mjolnir/resources"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_slab_basic_allocation :: proc(t: ^testing.T) {
  allocator: resources.SlabAllocator
  resources.slab_allocator_init(
    &allocator,
    {{10, 10}, {20, 10}, {}, {}, {}, {}, {}, {}},
  )
  defer resources.slab_allocator_destroy(&allocator)
  index, ok := resources.slab_alloc(&allocator, 10)
  testing.expect(t, ok)
  index, ok = resources.slab_alloc(&allocator, 20)
  testing.expect(t, ok)
  index, ok = resources.slab_alloc(&allocator, 30)
  testing.expect(t, !ok)
}

@(test)
test_slab_reuse :: proc(t: ^testing.T) {
  allocator: resources.SlabAllocator
  resources.slab_allocator_init(
    &allocator,
    {{10, 10}, {}, {}, {}, {}, {}, {}, {}},
  )
  indices: [10]u32
  defer resources.slab_allocator_destroy(&allocator)
  for i in 0 ..< 10 do indices[i] = resources.slab_alloc(&allocator, 10)
  index, ok := resources.slab_alloc(&allocator, 10)
  testing.expect(t, !ok)
  resources.slab_free(&allocator, indices[0])
  index, ok = resources.slab_alloc(&allocator, 10)
  testing.expect(t, ok)
}

@(test)
test_slab_invalid_free :: proc(t: ^testing.T) {
  allocator: resources.SlabAllocator
  resources.slab_allocator_init(
    &allocator,
    {{10, 10}, {}, {}, {}, {}, {}, {}, {}},
  )
  defer resources.slab_allocator_destroy(&allocator)
  resources.slab_free(&allocator, 0)
}

@(test)
benchmark_slab_allocation :: proc(t: ^testing.T) {
  n :: 1e7
  SlabTest :: struct {
    allocator: resources.SlabAllocator,
    ops:       []u32,
  }
  options := &time.Benchmark_Options {
    rounds = n,
    bytes = size_of(u32) * n,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      my_test := new(SlabTest)
      resources.slab_allocator_init(
        &my_test.allocator,
        {
          {10, 10000},
          {20, 10000},
          {50, 10000},
          {100, 20000},
          {400, 10000},
          {1000, 2000},
          {3000, 100},
          {6000, 100},
        },
      )
      my_test.ops = make([]u32, n)
      for &op in my_test.ops {
        op = u32(rand.int31() % 5000 + 1) // Random size between 1 and 5000
        if rand.float32() < 0.5 {
          op = 0
        }
      }
      options.input = slice.bytes_from_ptr(my_test, size_of(my_test))
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      my_test := cast(^SlabTest)(raw_data(options.input))
      allocated := make([dynamic]u32, 0, options.rounds)
      defer delete(allocated)
      for op in my_test.ops {
        if op > 0 {
          i, ok := resources.slab_alloc(&my_test.allocator, op)
          if ok {
            options.processed += size_of(u32)
            append(&allocated, i)
          }
        } else {
          i, ok := pop_safe(&allocated)
          if ok {
            resources.slab_free(&my_test.allocator, i)
            options.processed += size_of(u32)
          }
        }
      }
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      my_test := cast(^SlabTest)(raw_data(options.input))
      resources.slab_allocator_destroy(&my_test.allocator)
      delete(my_test.ops)
      free(my_test)
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
