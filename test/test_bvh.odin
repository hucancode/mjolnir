package tests

import "core:testing"
import "core:math"
import "core:math/linalg"
import "core:log"
import "core:time"
import "core:slice"
import "../mjolnir/geometry"

BVHTestItem :: struct {
  id:     i32,
  bounds: geometry.Aabb,
}

test_bvh_item_bounds :: proc(item: BVHTestItem) -> geometry.Aabb {
  return item.bounds
}

make_test_item :: proc(id: i32, center: [3]f32, size: f32) -> BVHTestItem {
  half_size := [3]f32{size, size, size} * 0.5
  return BVHTestItem{
    id = id,
    bounds = geometry.Aabb{
      min = center - half_size,
      max = center + half_size,
    },
  }
}

// Use case: Build spatial index from empty data
@(test)
test_bvh_build_from_empty_data :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  empty_items: []BVHTestItem
  geometry.bvh_build(&bvh, empty_items)

  testing.expect(t, len(bvh.nodes) == 0, "Empty BVH should have no nodes")
}

// Use case: Build spatial index from single item
@(test)
test_bvh_build_from_single_item :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  testing.expect(t, len(bvh.nodes) == 1, "Single item BVH should have 1 node")
}

// Use case: Build spatial index from multiple items
@(test)
test_bvh_build_from_multiple_items :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {-5, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, -5, 0}, 2),
    make_test_item(4, {0, 5, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  testing.expect(t, len(bvh.primitives) == 4, "Should have all 4 items")
}

// Use case: Find items in a box region
@(test)
test_bvh_find_items_in_box :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {10, 0, 0}, 2),
    make_test_item(3, {0, 10, 0}, 2),
  }
  
  geometry.bvh_build(&bvh, items)

  query_bounds := geometry.Aabb{
    min = {-5, -5, -5},
    max = {5, 5, 5},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 1, "Should find 1 item in box around origin")
}

// Use case: Find items in large area
@(test)
test_bvh_find_items_in_large_area :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {10, 0, 0}, 2),
    make_test_item(3, {0, 10, 0}, 2),
    make_test_item(4, {0, 0, 10}, 2),
  }
  
  geometry.bvh_build(&bvh, items)

  query_bounds := geometry.Aabb{
    min = {-5, -5, -5},
    max = {15, 15, 15},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 4, "Should find all 4 items in large area")
}

// Use case: Find nothing in empty region
@(test)
test_bvh_find_nothing_in_empty_region :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {10, 0, 0}, 2),
  }
  
  geometry.bvh_build(&bvh, items)

  // Query far away
  query_bounds := geometry.Aabb{
    min = {100, 100, 100},
    max = {200, 200, 200},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 0, "Should find no items in empty region")
}

// Use case: Find items along a ray
@(test)
test_bvh_find_items_along_ray :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {10, 0, 0}, 2),
    make_test_item(4, {0, 5, 0}, 2), // Not on ray
  }

  geometry.bvh_build(&bvh, items)

  ray := geometry.Ray{
    origin = {-10, 0, 0},
    direction = {1, 0, 0},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_ray(&bvh, ray, 25, &results)

  testing.expect(t, len(results) == 3, "Should find 3 items along X axis")
}

// Use case: Ray misses all items
@(test)
test_bvh_ray_misses_all_items :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  // Ray that misses
  ray := geometry.Ray{
    origin = {100, 100, 100},
    direction = {1, 0, 0},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_ray(&bvh, ray, 20, &results)

  testing.expect(t, len(results) == 0, "Should find no items for ray that misses")
}

// Use case: Find items within sphere (explosion radius)
@(test)
test_bvh_find_items_in_sphere :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {3, 0, 0}, 2),
    make_test_item(3, {0, 3, 0}, 2),
    make_test_item(4, {0, 0, 3}, 2),
    make_test_item(5, {10, 10, 10}, 2), // Far away
  }

  geometry.bvh_build(&bvh, items)

  center := [3]f32{0, 0, 0}
  radius := f32(4)

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_sphere(&bvh, center, radius, &results)

  testing.expect(t, len(results) == 4, "Should find 4 items within sphere")
}

// Use case: Find items in small sphere
@(test)
test_bvh_find_items_in_small_sphere :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {3, 0, 0}, 2),
    make_test_item(3, {0, 3, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  center := [3]f32{0, 0, 0}
  radius := f32(1.5)

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_sphere(&bvh, center, radius, &results)

  testing.expect(t, len(results) == 1, "Should find only item at origin")
}

// Use case: Find nearest item to a point
@(test)
test_bvh_find_nearest_item :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {10, 10, 10}, 2),
  }

  geometry.bvh_build(&bvh, items)

  point := [3]f32{0, 0, 0}
  result, _, found := geometry.bvh_query_nearest(&bvh, point)

  testing.expect(t, found, "Should find nearest item")
  testing.expect(t, result.id == 1, "Should find item at origin")
}

// Use case: Find nearest with distance limit
@(test)
test_bvh_find_nearest_within_distance :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {10, 10, 10}, 2),
  }

  geometry.bvh_build(&bvh, items)

  point := [3]f32{20, 20, 20}
  _, _, found := geometry.bvh_query_nearest(&bvh, point, 1)

  testing.expect(t, !found, "Should not find item beyond distance limit")
}

// Use case: Update tree after items move
@(test)
test_bvh_update_after_movement :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  // Move first item
  bvh.primitives[0] = make_test_item(1, {10, 10, 10}, 2)

  // Refit to update bounds
  geometry.bvh_refit(&bvh)

  // Verify it still works
  query_bounds := geometry.Aabb{
    min = {8, 8, 8},
    max = {12, 12, 12},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 1, "Should find moved item at new position")
}

// Use case: Handle identical positions
@(test)
test_bvh_handle_identical_positions :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 1),
    make_test_item(2, {0, 0, 0}, 1),
    make_test_item(3, {0, 0, 0}, 1),
  }

  geometry.bvh_build(&bvh, items)

  query_bounds := geometry.Aabb{
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 3, "Should find all items at same position")
}

// Use case: Handle zero-volume items
@(test)
test_bvh_handle_zero_volume_items :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 0),
    make_test_item(2, {1, 0, 0}, 0),
  }

  geometry.bvh_build(&bvh, items)

  query_bounds := geometry.Aabb{
    min = {-0.5, -0.5, -0.5},
    max = {0.5, 0.5, 0.5},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 1, "Should find zero-volume item at origin")
}

// Test robust ray intersection vs fast intersection
@(test)
test_bvh_robust_vs_fast_ray_intersection :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  // Test with edge case ray (nearly parallel to axis)
  ray := geometry.Ray{
    origin = {-10, 0, 1e-6},
    direction = linalg.normalize([3]f32{1, 0, 1e-7}),
  }

  results_fast := make([dynamic]BVHTestItem)
  defer delete(results_fast)
  geometry.bvh_query_ray(&bvh, ray, 25, &results_fast, false)

  results_robust := make([dynamic]BVHTestItem)
  defer delete(results_robust)
  geometry.bvh_query_ray(&bvh, ray, 25, &results_robust, true)

  // Both should find same items, robust version should be more stable
  testing.expect(t, len(results_fast) == len(results_robust), 
    "Fast and robust should find same number of items")
}

// Test BVH validation
@(test)
test_bvh_validation :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, 5, 0}, 2),
    make_test_item(4, {0, 0, 5}, 2),
  }

  geometry.bvh_build(&bvh, items)

  is_valid := geometry.bvh_validate(&bvh)
  testing.expect(t, is_valid, "Built BVH should be valid")
  
  stats := geometry.bvh_get_stats(&bvh)
  testing.expect(t, stats.total_nodes > 0, "Should have nodes")
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
  testing.expect(t, stats.total_primitives == 4, "Should count all primitives")
}

// Test BVH extraction
@(test)
test_bvh_extraction :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {10, 0, 0}, 2),
    make_test_item(4, {15, 0, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)
  
  // Extract subtree rooted at root
  extracted_bvh := geometry.bvh_extract(&bvh, 0)
  defer geometry.bvh_deinit(&extracted_bvh)
  
  testing.expect(t, len(extracted_bvh.nodes) > 0, "Extracted BVH should have nodes")
  testing.expect(t, len(extracted_bvh.primitives) > 0, "Extracted BVH should have primitives")
}

// Test custom traversal
@(test)
test_bvh_custom_traversal :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {10, 0, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)
  
  leaf_count := 0
  
  count_leaves :: proc(start, end: i32, user_data: rawptr) -> bool {
    count_ptr := cast(^int)user_data
    count_ptr^ += 1
    return false
  }
  
  geometry.bvh_traverse(&bvh, count_leaves, &leaf_count)
  
  testing.expect(t, leaf_count > 0, "Should visit some leaves during traversal")
}

// Performance benchmarks focused on realistic use cases

@(test)
bvh_static_scene_query_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(BVHTestItem))
    bvh_ptr.bounds_func = test_bvh_item_bounds

    // Build static scene
    item_count := 50000
    items := make([]BVHTestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 100 - 50) * 2
      y := f32((i / 100) % 100 - 50) * 2
      z := f32((i / 10000) % 100 - 50) * 2

      items[i] = BVHTestItem {
        id = i32(i),
        bounds = geometry.Aabb{
          min = {x - 0.6, y - 0.6, z - 0.6},
          max = {x + 0.6, y + 0.6, z + 0.6},
        },
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(BVHTestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(BVHTestItem))raw_data(options.input)
    results := make([dynamic]BVHTestItem, 0, 100)
    defer delete(results)

    // Simulate view frustum culling queries
    for i in 0 ..< options.rounds {
      clear(&results)
      
      offset := f32(i % 150 - 75) * 0.1
      query_bounds := geometry.Aabb {
        min = {-20 + offset, -20 + offset, -20 + offset},
        max = {20 + offset, 20 + offset, 20 + offset},
      }
      
      geometry.bvh_query_aabb(bvh_ptr, query_bounds, &results)
      options.processed += len(results) * size_of(BVHTestItem)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(BVHTestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 10000,
    bytes = size_of(BVHTestItem) * 100 * 10000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "Static scene query: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
bvh_ray_tracing_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(BVHTestItem))
    bvh_ptr.bounds_func = test_bvh_item_bounds

    // Build scene for ray tracing
    item_count := 20000
    items := make([]BVHTestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 50 - 25) * 2.5
      y := f32((i / 50) % 50 - 25) * 2.5
      z := f32((i / 2500) % 50 - 25) * 2.5

      items[i] = BVHTestItem {
        id = i32(i),
        bounds = geometry.Aabb{
          min = {x - 0.9, y - 0.9, z - 0.9},
          max = {x + 0.9, y + 0.9, z + 0.9},
        },
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(BVHTestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(BVHTestItem))raw_data(options.input)
    results := make([dynamic]BVHTestItem, 0, 50)
    defer delete(results)

    // Simulate ray tracing from camera
    for i in 0 ..< options.rounds {
      clear(&results)
      
      // Generate ray direction
      angle := f32(i) * 0.001
      ray := geometry.Ray {
        origin = {-60, -60 + f32(i % 120) * 0.1, -60},
        direction = linalg.normalize([3]f32{math.cos(angle), math.sin(angle), 0.7}),
      }
      
      geometry.bvh_query_ray(bvh_ptr, ray, 200, &results)
      options.processed += len(results) * size_of(BVHTestItem)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(BVHTestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 10000,
    bytes = size_of(BVHTestItem) * 30 * 10000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "Ray tracing: %d rays in %v (%.2f MB/s) | %.2f μs/ray",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
bvh_dynamic_scene_benchmark :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 15 * time.Second)
  
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(BVHTestItem))
    bvh_ptr.bounds_func = test_bvh_item_bounds

    item_count := 5000
    items := make([]BVHTestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 30 - 15) * 3
      y := f32((i / 30) % 30 - 15) * 3
      z := f32((i / 900) % 30 - 15) * 3

      items[i] = BVHTestItem {
        id = i32(i),
        bounds = geometry.Aabb{
          min = {x - 1.25, y - 1.25, z - 1.25},
          max = {x + 1.25, y + 1.25, z + 1.25},
        },
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(BVHTestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(BVHTestItem))raw_data(options.input)

    // Simulate dynamic scene with moving objects
    for frame in 0 ..< options.rounds {
      movement := f32(frame % 100 - 50) * 0.01
      
      // Move 10% of objects each frame
      items_to_move := len(bvh_ptr.primitives) / 10
      for i in 0 ..< items_to_move {
        idx := (frame * 7 + i) % len(bvh_ptr.primitives)
        bvh_ptr.primitives[idx].bounds.min.x += movement
        bvh_ptr.primitives[idx].bounds.max.x += movement
        bvh_ptr.primitives[idx].bounds.min.y += movement * 0.5
        bvh_ptr.primitives[idx].bounds.max.y += movement * 0.5
      }

      // Refit tree after movements
      geometry.bvh_refit(bvh_ptr)
      options.processed += items_to_move * size_of(BVHTestItem)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(BVHTestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 1000,
    bytes = size_of(BVHTestItem) * 500 * 1000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "Dynamic scene: %d frames in %v (%.2f MB/s) | %.2f ms/frame",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000000 / f64(options.rounds),
  )
}

// Stress test with large number of primitives
@(test)
test_bvh_large_scene_correctness :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  // Create large scene
  item_count := 10000
  items := make([]BVHTestItem, item_count)
  defer delete(items)

  for i in 0 ..< item_count {
    x := f32(i % 100 - 50) * 2
    y := f32((i / 100) % 100 - 50) * 2
    z := f32(i / 10000) * 2
    items[i] = make_test_item(i32(i), {x, y, z}, 1)
  }

  geometry.bvh_build(&bvh, items)
  
  // Validate large BVH
  is_valid := geometry.bvh_validate(&bvh)
  testing.expect(t, is_valid, "Large BVH should be valid")
  
  stats := geometry.bvh_get_stats(&bvh)
  testing.expect(t, stats.total_primitives == i32(item_count), "Should count all primitives")
  
  // Test queries on large scene
  query_bounds := geometry.Aabb{
    min = {-10, -10, -1},
    max = {10, 10, 1},
  }
  
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)
  
  testing.expect(t, len(results) > 0, "Should find items in large scene query")
  testing.expect(t, len(results) < item_count, "Should not find all items in partial query")
}