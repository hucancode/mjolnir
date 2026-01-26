package geometry

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

test_item_bounds :: proc(item: TestItem) -> Aabb {
  half_size := [3]f32{item.size, item.size, item.size} * 0.5
  return Aabb{min = item.pos - half_size, max = item.pos + half_size}
}

test_item_point :: proc(item: TestItem) -> [3]f32 {
  return item.pos
}

@(test)
test_octree_lifecycle :: proc(t: ^testing.T) {
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 4)
  testing.expect(t, octree.root != nil, "Root should not be nil")
  testing.expect(t, octree.max_depth == 5, "Max depth should be 5")
  testing.expect(t, octree.max_items == 4, "Max items should be 4")
  testing.expect(t, octree.root.depth == 0, "Root depth should be 0")
  testing.expect(
    t,
    len(octree.root.items) == 0,
    "Root should have no items initially",
  )
  octree_destroy(&octree)
  testing.expect(t, octree.root == nil, "Root should be nil after destroy")
}

@(test)
test_octree_insert :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  // Insert item in bounds
  item1 := TestItem {
    id   = 1,
    pos  = {0, 0, 0},
    size = 1,
  }
  result := octree_insert(&octree, item1)
  testing.expect(t, result == true, "Insert should succeed for item in bounds")
  // Insert item outside bounds
  item2 := TestItem {
    id   = 2,
    pos  = {15, 15, 15},
    size = 1,
  }
  result = octree_insert(&octree, item2)
  testing.expect(
    t,
    result == false,
    "Insert should fail for item outside bounds",
  )
  // Insert more items to trigger subdivision
  item3 := TestItem {
    id   = 3,
    pos  = {1, 1, 1},
    size = 1,
  }
  item4 := TestItem {
    id   = 4,
    pos  = {-1, -1, -1},
    size = 1,
  }
  item5 := TestItem {
    id   = 5,
    pos  = {2, 2, 2},
    size = 1,
  }
  octree_insert(&octree, item3)
  octree_insert(&octree, item4)
  octree_insert(&octree, item5)
  stats := octree_get_stats(&octree)
  testing.expect(t, stats.total_items == 4, "Should have 4 items total")
  testing.expect(t, stats.total_nodes > 1, "Should have subdivided")
}

@(test)
test_octree_query_aabb :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  items := []TestItem {
    {id = 1, pos = {0, 0, 0}, size = 1},
    {id = 2, pos = {5, 5, 5}, size = 1},
    {id = 3, pos = {-5, -5, -5}, size = 1},
    {id = 4, pos = {0, 5, 0}, size = 1},
  }
  for item in items {
    octree_insert(&octree, item)
  }
  // Query small area around origin
  query_bounds := Aabb {
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }
  results := make([dynamic]TestItem)
  defer delete(results)
  octree_query_aabb(&octree, query_bounds, &results)
  testing.expect(t, len(results) == 1, "Should find 1 item near origin")
  testing.expect(t, results[0].id == 1, "Should find item with id 1")
  // Query larger area
  query_bounds = Aabb {
    min = {-6, -6, -6},
    max = {6, 6, 6},
  }
  clear(&results)
  octree_query_aabb(&octree, query_bounds, &results)
  testing.expect(
    t,
    len(results) >= 3,
    "Should find at least 3 items in larger area",
  )
}

@(test)
test_octree_query_sphere :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  items := []TestItem {
    {id = 1, pos = {0, 0, 0}, size = 1},
    {id = 2, pos = {2, 0, 0}, size = 1},
    {id = 3, pos = {0, 2, 0}, size = 1},
    {id = 4, pos = {0, 0, 2}, size = 1},
    {id = 5, pos = {5, 5, 5}, size = 1},
  }
  for item in items {
    octree_insert(&octree, item)
  }
  // Query sphere around origin
  center := [3]f32{0, 0, 0}
  radius := f32(1.5)
  results := make([dynamic]TestItem)
  defer delete(results)
  octree_query_sphere(&octree, center, radius, &results)
  testing.expect(t, len(results) == 4, "Should find 4 items within radius")
  // Query smaller sphere
  radius = 0.5
  clear(&results)
  octree_query_sphere(&octree, center, radius, &results)
  testing.expect(
    t,
    len(results) == 1,
    "Should find 1 item within smaller radius",
  )
  testing.expect(t, results[0].id == 1, "Should find item at origin")
}

@(test)
test_octree_query_ray :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  items := []TestItem {
    {id = 1, pos = {0, 0, 0}, size = 1},
    {id = 2, pos = {1, 0, 0}, size = 1},
    {id = 3, pos = {2, 0, 0}, size = 1},
    {id = 4, pos = {0, 1, 0}, size = 1},
  }
  for item in items {
    octree_insert(&octree, item)
  }
  // Ray along X axis
  ray := Ray {
    origin    = {-5, 0, 0},
    direction = {1, 0, 0},
  }
  results := make([dynamic]TestItem)
  defer delete(results)
  octree_query_ray(&octree, ray, 10, &results)
  testing.expect(t, len(results) == 3, "Should find 3 items along X axis")
  // Ray along Y axis
  ray = Ray {
    origin    = {0, -5, 0},
    direction = {0, 1, 0},
  }
  clear(&results)
  octree_query_ray(&octree, ray, 10, &results)
  testing.expect(t, len(results) == 2, "Should find 2 items along Y axis")
}

@(test)
test_octree_remove :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  items := []TestItem {
    {id = 1, pos = {0, 0, 0}, size = 1},
    {id = 2, pos = {1, 1, 1}, size = 1},
    {id = 3, pos = {2, 2, 2}, size = 1},
  }
  for item in items {
    octree_insert(&octree, item)
  }
  initial_stats := octree_get_stats(&octree)
  testing.expect(
    t,
    initial_stats.total_items == 3,
    "Should have 3 items initially",
  )
  // Remove existing item
  result := octree_remove(&octree, items[1])
  testing.expect(t, result == true, "Should successfully remove existing item")
  stats := octree_get_stats(&octree)
  testing.expect(
    t,
    stats.total_items == 2,
    "Should have 2 items after removal",
  )
  // Try to remove non-existent item
  fake_item := TestItem {
    id   = 999,
    pos  = {0, 0, 0},
    size = 1,
  }
  result = octree_remove(&octree, fake_item)
  testing.expect(t, result == false, "Should fail to remove non-existent item")
  stats = octree_get_stats(&octree)
  testing.expect(t, stats.total_items == 2, "Should still have 2 items")
}

@(test)
test_octree_update :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  item := TestItem {
    id   = 1,
    pos  = {0, 0, 0},
    size = 1,
  }
  octree_insert(&octree, item)
  // Update item position
  old_item := item
  item.pos = {5, 5, 5}
  updated := octree_update(&octree, old_item, item)
  testing.expect(t, updated, "Should successfully update item")
  // Query old position
  query_bounds := Aabb {
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }
  results := make([dynamic]TestItem)
  defer delete(results)
  octree_query_aabb(&octree, query_bounds, &results)
  testing.expect(t, len(results) == 0, "Should find no items at old position")
  // Query new position
  query_bounds = Aabb {
    min = {4, 4, 4},
    max = {6, 6, 6},
  }
  clear(&results)
  octree_query_aabb(&octree, query_bounds, &results)
  testing.expect(
    t,
    len(results) == 1 && results[0].id == 1,
    "Should find item 1 at new position",
  )
}

@(test)
test_octree_subdivision :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 5, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  // Insert items to force subdivision
  items := []TestItem {
    {id = 1, pos = {-5, -5, -5}, size = 1},
    {id = 2, pos = {5, 5, 5}, size = 1},
    {id = 3, pos = {-5, 5, -5}, size = 1},
    {id = 4, pos = {5, -5, 5}, size = 1},
    {id = 5, pos = {0, 0, 0}, size = 1},
  }
  for item in items {
    octree_insert(&octree, item)
  }
  stats := octree_get_stats(&octree)
  testing.expect(t, stats.total_nodes > 1, "Should have subdivided")
  testing.expect(t, stats.total_items == 5, "Should have all 5 items")
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
}

@(test)
test_octree_edge_cases :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 2, 1)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  // Insert item exactly at boundary
  item := TestItem {
    id   = 1,
    pos  = {1, 1, 1},
    size = 0,
  }
  result := octree_insert(&octree, item)
  testing.expect(t, result == true, "Should handle boundary items")
  // Insert very small item
  item = TestItem {
    id   = 2,
    pos  = {0, 0, 0},
    size = 0.001,
  }
  result = octree_insert(&octree, item)
  testing.expect(t, result == true, "Should handle very small items")
  // Query empty region
  query_bounds := Aabb {
    min = {10, 10, 10},
    max = {20, 20, 20},
  }
  results := make([dynamic]TestItem)
  defer delete(results)
  octree_query_aabb(&octree, query_bounds, &results)
  testing.expect(t, len(results) == 0, "Should find no items in empty region")
}

@(test)
test_octree_stats :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bounds := Aabb {
    min = {-10, -10, -10},
    max = {10, 10, 10},
  }
  octree: Octree(TestItem)
  octree_init(&octree, bounds, 3, 2)
  defer octree_destroy(&octree)
  octree.bounds_func = test_item_bounds
  octree.point_func = test_item_point
  // Initial stats
  stats := octree_get_stats(&octree)
  testing.expect(t, stats.total_nodes == 1, "Should have 1 node initially")
  testing.expect(t, stats.leaf_nodes == 1, "Should have 1 leaf node initially")
  testing.expect(t, stats.total_items == 0, "Should have 0 items initially")
  // Add items
  for i in 0 ..< 10 {
    item := TestItem {
      id   = i32(i),
      pos  = {f32(i - 5), f32(i - 5), f32(i - 5)},
      size = 1,
    }
    octree_insert(&octree, item)
  }
  stats = octree_get_stats(&octree)
  testing.expect(t, stats.total_items == 10, "Should have 10 items")
  testing.expect(t, stats.total_nodes > 1, "Should have more than 1 node")
  testing.expect(t, stats.max_depth >= 0, "Max depth should be non-negative")
}

@(test)
octree_single_insert_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Pre-populate with 5000 items to simulate realistic game world
    for i in 0 ..< 5000 {
      x := f32(i % 50 - 25) * 3
      y := f32((i / 50) % 50 - 25) * 3
      z := f32((i / 2500) % 50 - 25) * 3
      item := TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 1,
      }
      octree_insert(octree_ptr, item)
    }
    options.input = slice.bytes_from_ptr(
      octree_ptr,
      size_of(^Octree(TestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    for i in 0 ..< options.rounds {
      // Vary position for each insert
      varied_item := TestItem {
        id   = i32(i + 100000),
        pos  = {f32(i % 100 - 50) * 0.1, f32((i / 100) % 100 - 50) * 0.1, 0},
        size = 1,
      }
      octree_insert(octree_ptr, varied_item)
      options.processed += size_of(TestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    octree_destroy(octree_ptr)
    free(octree_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds   = 10000, // 10k single inserts
    bytes    = size_of(TestItem) * 10000,
    setup    = setup_proc,
    bench    = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Single insert benchmark: %d inserts in %v (%.2f MB/s) | %.2f μs/insert",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
octree_single_remove_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  BenchmarkData :: struct {
    octree_ptr: ^Octree(TestItem),
    items:      []TestItem,
  }
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Pre-populate with removable items
    removable_items := make([]TestItem, 15000)
    for i in 0 ..< 15000 {
      x := f32(i % 50 - 25) * 3
      y := f32((i / 50) % 50 - 25) * 3
      z := f32((i / 2500) % 50 - 25) * 3
      removable_items[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 1,
      }
      octree_insert(octree_ptr, removable_items[i])
    }
    bench_data := new(BenchmarkData)
    bench_data.octree_ptr = octree_ptr
    bench_data.items = removable_items
    options.input = slice.bytes_from_ptr(bench_data, size_of(^BenchmarkData))
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bench_data := cast(^BenchmarkData)raw_data(options.input)
    for i in 0 ..< options.rounds {
      // Remove items cyclically
      item_index := i % len(bench_data.items)
      octree_remove(
        bench_data.octree_ptr,
        bench_data.items[item_index],
      )
      options.processed += size_of(TestItem)
      // Re-insert to maintain structure for next iterations
      octree_insert(
        bench_data.octree_ptr,
        bench_data.items[item_index],
      )
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bench_data := cast(^BenchmarkData)raw_data(options.input)
    octree_destroy(bench_data.octree_ptr)
    free(bench_data.octree_ptr)
    delete(bench_data.items)
    free(bench_data)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = 10000,
    bytes = size_of(TestItem) * 10000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Single remove benchmark: %d removes in %v (%.2f MB/s) | %.2f μs/remove",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
octree_optimized_query_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Dense population for realistic game world
    item_count := 20000
    for i in 0 ..< item_count {
      x := f32(i % 100 - 50) * 1.5
      y := f32((i / 100) % 100 - 50) * 1.5
      z := f32((i / 10000) % 100 - 50) * 1.5
      item := TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 0.8,
      }
      octree_insert(octree_ptr, item)
    }
    options.input = slice.bytes_from_ptr(
      octree_ptr,
      size_of(Octree(TestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree := cast(^Octree(TestItem))raw_data(options.input)
    results := make([dynamic]TestItem, 0, 100)
    defer delete(results)
    for i in 0 ..< options.rounds {
      clear(&results)
      // Small query region (typical for collision detection)
      offset := f32(i % 200 - 100) * 0.3
      query_bounds := Aabb {
        min = {-5 + offset, -5 + offset, -5 + offset},
        max = {5 + offset, 5 + offset, 5 + offset},
      }
      octree_query_aabb(octree, query_bounds, &results)
      options.processed += len(results) * size_of(TestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    octree_destroy(octree_ptr)
    free(octree_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds   = 50000, // 50k queries per benchmark
    bytes    = size_of(TestItem) * 20 * 50000, // avg 20 items per query
    setup    = setup_proc,
    bench    = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Optimized query benchmark: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
octree_realistic_insert_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Pre-populate with 5000 items to simulate realistic game world
    for i in 0 ..< 5000 {
      x := f32(i % 50 - 25) * 2
      y := f32((i / 50) % 50 - 25) * 2
      z := f32((i / 2500) % 50 - 25) * 2
      item := TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 0.8,
      }
      octree_insert(octree_ptr, item)
    }
    options.input = slice.bytes_from_ptr(
      octree_ptr,
      size_of(^Octree(TestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    for i in 0 ..< options.rounds {
      // Create a unique item for each insert
      item := TestItem {
        id   = i32(i + 100000),
        pos  = {
          f32(i % 100 - 50) * 0.1,
          f32((i / 100) % 100 - 50) * 0.1,
          f32((i / 10000) % 100 - 50) * 0.1,
        },
        size = 0.8,
      }
      octree_insert(octree_ptr, item)
      options.processed += size_of(TestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    octree_destroy(octree_ptr)
    free(octree_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = 10000,
    bytes = size_of(TestItem) * 10000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Realistic insert: %d inserts in %v (%.2f MB/s) | %.2f μs/insert",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
octree_realistic_remove_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  BenchmarkData :: struct {
    octree_ptr: ^Octree(TestItem),
    items:      []TestItem,
  }
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Pre-populate with items we can remove
    item_pool := make([]TestItem, 10000)
    for i in 0 ..< 10000 {
      x := f32(i % 50 - 25) * 2
      y := f32((i / 50) % 50 - 25) * 2
      z := f32((i / 2500) % 50 - 25) * 2
      item_pool[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 0.8,
      }
      octree_insert(octree_ptr, item_pool[i])
    }
    bench_data := new(BenchmarkData)
    bench_data.octree_ptr = octree_ptr
    bench_data.items = item_pool
    options.input = slice.bytes_from_ptr(bench_data, size_of(^BenchmarkData))
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bench_data := cast(^BenchmarkData)raw_data(options.input)
    for i in 0 ..< options.rounds {
      // Remove and re-insert to maintain octree state
      item_index := i % len(bench_data.items)
      removed := octree_remove(
        bench_data.octree_ptr,
        bench_data.items[item_index],
      )
      // Re-insert for next iteration
      if removed {
        octree_insert(
          bench_data.octree_ptr,
          bench_data.items[item_index],
        )
      }
      options.processed += size_of(TestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bench_data := cast(^BenchmarkData)raw_data(options.input)
    octree_destroy(bench_data.octree_ptr)
    free(bench_data.octree_ptr)
    delete(bench_data.items)
    free(bench_data)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = 10000,
    bytes = size_of(TestItem) * 10000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Realistic remove: %d removes in %v (%.2f MB/s) | %.2f μs/remove",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
octree_realistic_query_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Dense population for realistic game world
    for i in 0 ..< 15000 {
      x := f32(i % 80 - 40) * 1.2
      y := f32((i / 80) % 80 - 40) * 1.2
      z := f32((i / 6400) % 80 - 40) * 1.2
      item := TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 0.8,
      }
      octree_insert(octree_ptr, item)
    }
    options.input = slice.bytes_from_ptr(
      octree_ptr,
      size_of(^Octree(TestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    results := make([dynamic]TestItem, 0, 50)
    defer delete(results)
    for i in 0 ..< options.rounds {
      // Character-shaped query region (wider vertically)
      offset := f32(i % 200 - 100) * 0.05
      query_bounds := Aabb {
        min = {-0.25 + offset, -0.5 + offset, -0.25 + offset},
        max = {0.25 + offset, 0.5 + offset, 0.25 + offset},
      }
      // Use limited query to avoid processing too many results
      octree_query_aabb_limited(
        octree_ptr,
        query_bounds,
        &results,
        10,
      )
      options.processed += len(results) * size_of(TestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    octree_destroy(octree_ptr)
    free(octree_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds   = 10000,
    bytes    = size_of(TestItem) * 15 * 10000, // Estimate ~15 items per query
    setup    = setup_proc,
    bench    = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Realistic query: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
octree_frame_simulation_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  BenchmarkData :: struct {
    octree_ptr: ^Octree(TestItem),
    items:      []TestItem,
  }
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Initial world population
    world_items := make([]TestItem, 6000)
    for i in 0 ..< 6000 {
      x := f32(i % 50 - 25) * 2
      y := f32((i / 50) % 50 - 25) * 2
      z := f32((i / 2500) % 50 - 25) * 2
      world_items[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 1,
      }
      octree_insert(octree_ptr, world_items[i])
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
    for i in 0 ..< options.rounds {
      frame_offset := f32(i % 100 - 50) * 0.15
      // 1. Multiple queries per frame (collision detection, AI)
      for q in 0 ..< 3 {
        clear(&results)
        query_pos := f32(q) * 10 + frame_offset
        query_bounds := Aabb {
          min = {-4 + query_pos, -4 + query_pos, -4 + query_pos},
          max = {4 + query_pos, 4 + query_pos, 4 + query_pos},
        }
        octree_query_aabb(
          bench_data.octree_ptr,
          query_bounds,
          &results,
        )
      }
      // 2. Occasional object destruction
      if i % 20 == 0 && len(bench_data.items) > 0 {
        remove_item := bench_data.items[i % len(bench_data.items)]
        octree_remove(bench_data.octree_ptr, remove_item)
      }
      // 3. Occasional object spawning
      if i % 15 == 0 {
        new_item := TestItem {
          id   = i32(i + 100000),
          pos  = {frame_offset * 8, frame_offset * 8, frame_offset * 8},
          size = 1,
        }
        octree_insert(bench_data.octree_ptr, new_item)
      }
      options.processed += size_of(TestItem) * 10 // Rough estimate
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bench_data := cast(^BenchmarkData)raw_data(options.input)
    octree_destroy(bench_data.octree_ptr)
    free(bench_data.octree_ptr)
    delete(bench_data.items)
    free(bench_data)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds   = 1000, // 1000 "frames"
    bytes    = size_of(TestItem) * 100 * 1000, // Est. operations per frame
    setup    = setup_proc,
    bench    = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Frame simulation: %d frames in %v (%.2f MB/s) | %.2f ms/frame",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000000 / f64(options.rounds),
  )
}

@(test)
octree_empty_query_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bounds := Aabb {
      min = {-100, -100, -100},
      max = {100, 100, 100},
    }
    octree_ptr := new(Octree(TestItem))
    octree_ptr^ = Octree(TestItem){}
    octree_init(octree_ptr, bounds, 8, 16)
    octree_ptr.bounds_func = test_item_bounds
    octree_ptr.point_func = test_item_point
    // Populate only the negative region
    for i in 0 ..< 10000 {
      x := f32(i % 50 - 75) * 1.2 // -75 to -25
      y := f32((i / 50) % 50 - 75) * 1.2
      z := f32((i / 2500) % 50 - 75) * 1.2
      item := TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 0.8,
      }
      octree_insert(octree_ptr, item)
    }
    options.input = slice.bytes_from_ptr(
      octree_ptr,
      size_of(^Octree(TestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    results := make([dynamic]TestItem, 0, 50)
    defer delete(results)
    for i in 0 ..< options.rounds {
      // Query the positive region where no items exist
      offset := f32(i % 200 - 100) * 0.05
      query_bounds := Aabb {
        min = {50 + offset, 50 + offset, 50 + offset},
        max = {60 + offset, 60 + offset, 60 + offset},
      }
      octree_query_aabb(octree_ptr, query_bounds, &results)
      options.processed += len(results) * size_of(TestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    octree_ptr := cast(^Octree(TestItem))raw_data(options.input)
    octree_destroy(octree_ptr)
    free(octree_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds   = 10000,
    bytes    = size_of(TestItem) * 0 * 10000, // No items found, but still process queries
    setup    = setup_proc,
    bench    = bench_proc,
    teardown = teardown_proc,
  }
  err := time.benchmark(options)
  log.infof(
    "Empty query: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}
