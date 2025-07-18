package tests

import "../mjolnir/geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

TestItem :: struct {
  id:   i32,
  pos:  [3]f32,
  size: f32,
}

test_item_bounds :: proc(item: TestItem) -> geometry.Aabb {
  half_size := [3]f32{item.size, item.size, item.size} * 0.5
  return geometry.Aabb{min = item.pos - half_size, max = item.pos + half_size}
}

test_item_point :: proc(item: TestItem) -> [3]f32 {
  return item.pos
}

// Use case: Create a spatial index for a game world
@(test)
test_octree_create_spatial_index :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-100, -100, -100},
    max = {100, 100, 100},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 4)
  defer geometry.octree_deinit(&octree)

  testing.expect(t, octree.root != nil, "Octree should be initialized")
}

// Use case: Add an item to the world
@(test)
test_octree_add_item :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  item := TestItem {
    id   = 1,
    pos  = {0, 0, 0},
    size = 1,
  }
  
  result := geometry.octree_insert(&octree, item)
  testing.expect(t, result == true, "Should successfully add item to world")
}

// Use case: Reject items outside world bounds
@(test)
test_octree_reject_out_of_bounds_item :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  item := TestItem {
    id   = 1,
    pos  = {100, 100, 100}, // Far outside bounds
    size = 1,
  }
  
  result := geometry.octree_insert(&octree, item)
  testing.expect(t, result == false, "Should reject item outside world bounds")
}

// Use case: Find items in a box region
@(test)
test_octree_find_items_in_box :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  // Add test items
  items := []TestItem {
    {id = 1, pos = {0, 0, 0}, size = 1},
    {id = 2, pos = {5, 5, 5}, size = 1},
    {id = 3, pos = {-5, -5, -5}, size = 1},
  }

  for item in items {
    geometry.octree_insert(&octree, item)
  }

  // Query box around origin
  query_box := geometry.Aabb {
    min = {-2, -2, -2},
    max = {2, 2, 2},
  }

  results := make([dynamic]TestItem)
  defer delete(results)
  geometry.octree_query_aabb(&octree, query_box, &results)

  testing.expect(t, len(results) == 1, "Should find 1 item in box around origin")
  if len(results) > 0 {
    testing.expect(t, results[0].id == 1, "Should find the item at origin")
  }
}

// Use case: Find items within a sphere (e.g., explosion radius)
@(test)
test_octree_find_items_in_sphere :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  // Add test items
  items := []TestItem {
    {id = 1, pos = {0, 0, 0}, size = 1},
    {id = 2, pos = {2, 0, 0}, size = 1},
    {id = 3, pos = {5, 0, 0}, size = 1},
  }

  for item in items {
    geometry.octree_insert(&octree, item)
  }

  // Query sphere with radius 3
  center := [3]f32{0, 0, 0}
  radius := f32(3)

  results := make([dynamic]TestItem)
  defer delete(results)
  geometry.octree_query_sphere(&octree, center, radius, &results)

  testing.expect(t, len(results) == 2, "Should find 2 items within radius 3")
}

// Use case: Find items along a ray (e.g., gunfire)
@(test)
test_octree_find_items_along_ray :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  // Add items along X axis
  items := []TestItem {
    {id = 1, pos = {0, 0, 0}, size = 1},
    {id = 2, pos = {2, 0, 0}, size = 1},
    {id = 3, pos = {4, 0, 0}, size = 1},
    {id = 4, pos = {0, 2, 0}, size = 1}, // Not on ray path
  }

  for item in items {
    geometry.octree_insert(&octree, item)
  }

  // Ray along X axis
  ray := geometry.Ray {
    origin    = {-5, 0, 0},
    direction = {1, 0, 0},
  }

  results := make([dynamic]TestItem)
  defer delete(results)
  geometry.octree_query_ray(&octree, ray, 10, &results)

  testing.expect(t, len(results) == 3, "Should find 3 items along X axis")
}

// Use case: Remove an item from the world
@(test)
test_octree_remove_item :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  item := TestItem {
    id   = 1,
    pos  = {0, 0, 0},
    size = 1,
  }

  geometry.octree_insert(&octree, item)
  result := geometry.octree_remove(&octree, item)
  
  testing.expect(t, result == true, "Should successfully remove existing item")
}

// Use case: Fail to remove non-existent item
@(test)
test_octree_remove_nonexistent_item :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  item := TestItem {
    id   = 999,
    pos  = {0, 0, 0},
    size = 1,
  }

  result := geometry.octree_remove(&octree, item)
  testing.expect(t, result == false, "Should fail to remove non-existent item")
}

// Use case: Move an item to a new position
@(test)
test_octree_move_item :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  old_item := TestItem {
    id   = 1,
    pos  = {0, 0, 0},
    size = 1,
  }
  
  new_item := TestItem {
    id   = 1,
    pos  = {5, 5, 5},
    size = 1,
  }

  geometry.octree_insert(&octree, old_item)
  result := geometry.octree_update(&octree, old_item, new_item)
  
  testing.expect(t, result == true, "Should successfully move item to new position")
}

// Use case: Find nothing in empty region
@(test)
test_octree_find_nothing_in_empty_region :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 5, 2)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  // Add items only in negative region
  items := []TestItem {
    {id = 1, pos = {-5, -5, -5}, size = 1},
    {id = 2, pos = {-7, -7, -7}, size = 1},
  }

  for item in items {
    geometry.octree_insert(&octree, item)
  }

  // Query positive region where no items exist
  query_box := geometry.Aabb {
    min = {5, 5, 5},
    max = {9, 9, 9},
  }

  results := make([dynamic]TestItem)
  defer delete(results)
  geometry.octree_query_aabb(&octree, query_box, &results)

  testing.expect(t, len(results) == 0, "Should find no items in empty region")
}

// Use case: Handle items at exact boundary
@(test)
test_octree_handle_boundary_items :: proc(t: ^testing.T) {
  bounds := geometry.Aabb {
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }

  octree: geometry.Octree(TestItem)
  geometry.octree_init(&octree, bounds, 2, 1)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  defer geometry.octree_deinit(&octree)

  // Item exactly at boundary
  item := TestItem {
    id   = 1,
    pos  = {1, 1, 1},
    size = 0,
  }
  
  result := geometry.octree_insert(&octree, item)
  testing.expect(t, result == true, "Should handle items at exact boundary")
}

// Performance benchmarks focused on realistic use cases

@(test)
octree_collision_detection_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }

    octree_ptr := new(geometry.Octree(TestItem))
    octree_ptr^ = geometry.Octree(TestItem){}
    geometry.octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point

    // Populate with game objects
    for i in 0 ..< 10000 {
      x := f32(i % 100 - 50) * 1.5
      y := f32((i / 100) % 100 - 50) * 1.5
      z := f32((i / 10000) % 100 - 50) * 1.5

      item := TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 0.8,
      }
      geometry.octree_insert(octree_ptr, item)
    }

    options.input = slice.bytes_from_ptr(octree_ptr, size_of(geometry.Octree(TestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree := cast(^geometry.Octree(TestItem))raw_data(options.input)
    results := make([dynamic]TestItem, 0, 100)
    defer delete(results)

    // Simulate collision detection queries for moving objects
    for i in 0 ..< options.rounds {
      clear(&results)

      // Character-sized collision box
      offset := f32(i % 200 - 100) * 0.3
      query_bounds := geometry.Aabb {
        min = {-1 + offset, -2 + offset, -1 + offset},
        max = {1 + offset, 2 + offset, 1 + offset},
      }

      geometry.octree_query_aabb(octree, query_bounds, &results)
      options.processed += len(results) * size_of(TestItem)
    }

    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^geometry.Octree(TestItem))raw_data(options.input)
    geometry.octree_deinit(octree_ptr)
    free(octree_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 50000,
    bytes = size_of(TestItem) * 20 * 50000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "Collision detection: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
octree_dynamic_world_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  
  BenchmarkData :: struct {
    octree_ptr: ^geometry.Octree(TestItem),
    items: []TestItem,
  }

  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := geometry.Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }

    octree_ptr := new(geometry.Octree(TestItem))
    octree_ptr^ = geometry.Octree(TestItem){}
    geometry.octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point

    // Initial world population
    world_items := make([]TestItem, 5000)

    for i in 0 ..< 5000 {
      x := f32(i % 50 - 25) * 2
      y := f32((i / 50) % 50 - 25) * 2
      z := f32((i / 2500) % 50 - 25) * 2

      world_items[i] = TestItem {
        id = i32(i),
        pos = {x, y, z},
        size = 1,
      }
      geometry.octree_insert(octree_ptr, world_items[i])
    }

    bench_data := new(BenchmarkData)
    bench_data.octree_ptr = octree_ptr
    bench_data.items = world_items

    options.input = slice.bytes_from_ptr(bench_data, size_of(^BenchmarkData))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bench_data := cast(^BenchmarkData)raw_data(options.input)
    results := make([dynamic]TestItem, 0, 30)
    defer delete(results)

    // Simulate a game frame with various operations
    for frame in 0 ..< options.rounds {
      frame_offset := f32(frame % 100 - 50) * 0.15

      // 1. Query for nearby objects (AI visibility, collision)
      for q in 0 ..< 3 {
        clear(&results)
        query_pos := f32(q) * 10 + frame_offset
        query_bounds := geometry.Aabb {
          min = {-4 + query_pos, -4 + query_pos, -4 + query_pos},
          max = {4 + query_pos, 4 + query_pos, 4 + query_pos},
        }
        geometry.octree_query_aabb(bench_data.octree_ptr, query_bounds, &results)
      }

      // 2. Move some objects
      if frame % 5 == 0 && len(bench_data.items) > 0 {
        item_idx := frame % len(bench_data.items)
        old_item := bench_data.items[item_idx]
        new_item := old_item
        new_item.pos.x += frame_offset * 0.1
        new_item.pos.y += frame_offset * 0.1
        
        if geometry.octree_update(bench_data.octree_ptr, old_item, new_item) {
          bench_data.items[item_idx] = new_item
        }
      }

      // 3. Spawn new object
      if frame % 30 == 0 {
        new_item := TestItem {
          id = i32(frame + 100000),
          pos = {frame_offset * 8, frame_offset * 8, 0},
          size = 1,
        }
        geometry.octree_insert(bench_data.octree_ptr, new_item)
      }

      // 4. Remove old object
      if frame % 40 == 0 && len(bench_data.items) > 100 {
        remove_idx := (frame * 7) % len(bench_data.items)
        geometry.octree_remove(bench_data.octree_ptr, bench_data.items[remove_idx])
      }

      options.processed += size_of(TestItem) * 10
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bench_data := cast(^BenchmarkData)raw_data(options.input)
    geometry.octree_deinit(bench_data.octree_ptr)
    free(bench_data.octree_ptr)
    delete(bench_data.items)
    free(bench_data)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 1000,
    bytes = size_of(TestItem) * 100 * 1000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "Dynamic world: %d frames in %v (%.2f MB/s) | %.2f ms/frame",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000000 / f64(options.rounds),
  )
}