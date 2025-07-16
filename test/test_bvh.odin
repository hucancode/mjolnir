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

@(test)
test_bvh_build_empty :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  empty_items: []BVHTestItem
  geometry.bvh_build(&bvh, empty_items)

  testing.expect(t, len(bvh.nodes) == 0, "Empty BVH should have no nodes")
  testing.expect(t, len(bvh.primitives) == 0, "Empty BVH should have no primitives")
}

@(test)
test_bvh_build_single_item :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  testing.expect(t, len(bvh.nodes) == 1, "Single item BVH should have 1 node")
  testing.expect(t, len(bvh.primitives) == 1, "Single item BVH should have 1 primitive")
  testing.expect(t, bvh.nodes[0].left_child == -1, "Single item node should be a leaf")
  testing.expect(t, bvh.nodes[0].primitive_count == 1, "Single item node should have 1 primitive")
}

@(test)
test_bvh_build_multiple_items :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {-5, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, -5, 0}, 2),
    make_test_item(4, {0, 5, 0}, 2),
    make_test_item(5, {0, 0, -5}, 2),
    make_test_item(6, {0, 0, 5}, 2),
  }

  geometry.bvh_build(&bvh, items, 2)

  testing.expect(t, len(bvh.nodes) > 1, "Multiple items should create multiple nodes")
  testing.expect(t, len(bvh.primitives) == 6, "Should have all 6 primitives")

  // Validate tree structure
  testing.expect(t, geometry.bvh_validate(&bvh), "BVH should be valid")

  stats := geometry.bvh_get_stats(&bvh)
  testing.expect(t, stats.total_nodes > 1, "Should have multiple nodes")
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
  testing.expect(t, stats.internal_nodes > 0, "Should have internal nodes")
  testing.expect(t, stats.total_primitives == 6, "Should have all primitives")
}

@(test)
test_bvh_query_aabb :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {10, 0, 0}, 2),
    make_test_item(3, {0, 10, 0}, 2),
    make_test_item(4, {0, 0, 10}, 2),
    make_test_item(5, {20, 20, 20}, 2),
  }
  geometry.bvh_build(&bvh, items)
  // Query near origin
  query_bounds := geometry.Aabb{
    min = {-5, -5, -5},
    max = {5, 5, 5},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 1, "Should find 1 item near origin")
  testing.expect(t, results[0].id == 1, "Should find the item at origin")

  // Query larger area
  query_bounds = geometry.Aabb{
    min = {-5, -5, -5},
    max = {15, 15, 15},
  }

  clear(&results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 4, "Should find 4 items in larger area")

  // Query empty area
  query_bounds = geometry.Aabb{
    min = {100, 100, 100},
    max = {200, 200, 200},
  }

  clear(&results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 0, "Should find no items in empty area")
}

@(test)
test_bvh_query_ray :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {10, 0, 0}, 2),
    make_test_item(4, {0, 5, 0}, 2),
    make_test_item(5, {0, 0, 5}, 2),
  }

  geometry.bvh_build(&bvh, items)


  // Ray along X axis
  ray := geometry.Ray{
    origin = {-10, 0, 0},
    direction = {1, 0, 0},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_ray(&bvh, ray, 20, &results)

  testing.expect(t, len(results) == 3, "Should find 3 items along X axis")

  // Ray along Y axis
  ray = geometry.Ray{
    origin = {0, -10, 0},
    direction = {0, 1, 0},
  }

  clear(&results)
  geometry.bvh_query_ray(&bvh, ray, 20, &results)


  testing.expect(t, len(results) == 2, "Should find 2 items along Y axis")

  // Ray that misses everything
  ray = geometry.Ray{
    origin = {100, 100, 100},
    direction = {1, 0, 0},
  }

  clear(&results)
  geometry.bvh_query_ray(&bvh, ray, 20, &results)

  testing.expect(t, len(results) == 0, "Should find no items for ray that misses")
}

@(test)
test_bvh_query_sphere :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {3, 0, 0}, 2),
    make_test_item(3, {0, 3, 0}, 2),
    make_test_item(4, {0, 0, 3}, 2),
    make_test_item(5, {10, 10, 10}, 2),
  }

  geometry.bvh_build(&bvh, items)

  // Query sphere around origin
  center := [3]f32{0, 0, 0}
  radius := f32(4)

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_sphere(&bvh, center, radius, &results)

  testing.expect(t, len(results) == 4, "Should find 4 items within sphere")

  // Query smaller sphere
  radius = 1.5
  clear(&results)
  geometry.bvh_query_sphere(&bvh, center, radius, &results)

  testing.expect(t, len(results) == 1, "Should find 1 item within smaller sphere")
  testing.expect(t, results[0].id == 1, "Should find the item at origin")

  // Query sphere in empty area
  center = [3]f32{100, 100, 100}
  radius = 5

  clear(&results)
  geometry.bvh_query_sphere(&bvh, center, radius, &results)

  testing.expect(t, len(results) == 0, "Should find no items in empty sphere")
}

@(test)
test_bvh_query_nearest :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, 5, 0}, 2),
    make_test_item(4, {0, 0, 5}, 2),
    make_test_item(5, {10, 10, 10}, 2),
  }

  geometry.bvh_build(&bvh, items)

  // Query nearest to origin
  point := [3]f32{0, 0, 0}
  result, dist, found := geometry.bvh_query_nearest(&bvh, point)

  testing.expect(t, found, "Should find nearest item")
  testing.expect(t, result.id == 1, "Should find item at origin")
  testing.expect(t, dist == 0, "Distance should be 0")

  // Query nearest to a point not at origin
  point = [3]f32{4, 0, 0}
  result, dist, found = geometry.bvh_query_nearest(&bvh, point)

  testing.expect(t, found, "Should find nearest item")
  testing.expect(t, result.id == 2, "Should find item at (5,0,0)")
  testing.expect(t, dist == 0, "Distance should be 0 (point inside AABB)")

  // Query with max distance limit
  point = [3]f32{0, 0, 0}
  result, dist, found = geometry.bvh_query_nearest(&bvh, point, 0.5)

  testing.expect(t, found, "Should find item within max distance")
  testing.expect(t, result.id == 1, "Should find closest item")

  // Query with very small max distance
  point = [3]f32{20, 20, 20}
  result, dist, found = geometry.bvh_query_nearest(&bvh, point, 1)

  testing.expect(t, !found, "Should not find any item within small max distance")
}

@(test)
test_bvh_refit :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, 5, 0}, 2),
  }

  geometry.bvh_build(&bvh, items)

  // Store original root bounds
  original_bounds := bvh.nodes[0].bounds

  // Modify primitives
  bvh.primitives[0] = make_test_item(1, {10, 10, 10}, 2)
  bvh.primitives[1] = make_test_item(2, {15, 0, 0}, 2)

  // Refit the tree
  geometry.bvh_refit(&bvh)

  // Check that bounds have been updated
  new_bounds := bvh.nodes[0].bounds
  testing.expect(t, new_bounds.min != original_bounds.min || new_bounds.max != original_bounds.max,
                 "Root bounds should have changed after refit")

  // Tree should still be valid
  testing.expect(t, geometry.bvh_validate(&bvh), "BVH should still be valid after refit")
}

@(test)
test_bvh_validate :: proc(t: ^testing.T) {
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
  // Valid tree should pass validation
  valid := geometry.bvh_validate(&bvh)
  testing.expect(t, valid, "Properly built BVH should be valid")

  // Corrupt the tree and check it fails validation
  if len(bvh.nodes) > 0 {
    original_count := bvh.nodes[0].primitive_count
    bvh.nodes[0].primitive_count = -1
    corrupted_valid := geometry.bvh_validate(&bvh)
    testing.expect(t, !corrupted_valid, "Corrupted BVH should fail validation")
    bvh.nodes[0].primitive_count = original_count
  }
}

@(test)
test_bvh_stats :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, 5, 0}, 2),
    make_test_item(4, {0, 0, 5}, 2),
    make_test_item(5, {10, 10, 10}, 2),
  }

  geometry.bvh_build(&bvh, items, 2)

  stats := geometry.bvh_get_stats(&bvh)

  testing.expect(t, stats.total_nodes > 0, "Should have nodes")
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
  testing.expect(t, stats.total_primitives == 5, "Should have all primitives")
  testing.expect(t, stats.max_leaf_size <= 2, "Max leaf size should respect limit")
  testing.expect(t, stats.total_nodes == stats.leaf_nodes + stats.internal_nodes,
                 "Total nodes should equal leaf + internal nodes")
}

@(test)
test_bvh_large_dataset :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  // Create a large dataset
  item_count := 1000
  items := make([]BVHTestItem, item_count)

  for i in 0..<item_count {
    x := f32(i % 10) * 2 - 10
    y := f32((i / 10) % 10) * 2 - 10
    z := f32((i / 100) % 10) * 2 - 10

    items[i] = make_test_item(i32(i), {x, y, z}, 1)
  }

  geometry.bvh_build(&bvh, items)

  // Verify all items are in the BVH
  testing.expect(t, len(bvh.primitives) == item_count, "Should have all items")
  testing.expect(t, geometry.bvh_validate(&bvh), "Large BVH should be valid")

  // Query a small region and verify performance
  query_bounds := geometry.Aabb{
    min = {-2, -2, -2},
    max = {2, 2, 2},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) > 0, "Should find items in query region")
  testing.expect(t, len(results) < item_count, "Should not find all items")

  // Verify found items are actually in the query region
  for item in results {
    testing.expect(t, geometry.aabb_intersects(item.bounds, query_bounds),
                   "All found items should intersect query bounds")
  }

  stats := geometry.bvh_get_stats(&bvh)
  testing.expect(t, stats.total_nodes > 1, "Large dataset should create multiple nodes")
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
  testing.expect(t, stats.internal_nodes > 0, "Should have internal nodes")
}

@(test)
test_bvh_sah_splitting :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  // Create items that should benefit from SAH splitting
  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 1),
    make_test_item(2, {1, 0, 0}, 1),
    make_test_item(3, {2, 0, 0}, 1),
    make_test_item(4, {3, 0, 0}, 1),
    make_test_item(5, {4, 0, 0}, 1),
    make_test_item(6, {100, 100, 100}, 1),
  }

  geometry.bvh_build(&bvh, items, 2)

  testing.expect(t, geometry.bvh_validate(&bvh), "SAH-built BVH should be valid")

  // Query for tightly packed items
  query_bounds := geometry.Aabb{
    min = {-1, -1, -1},
    max = {5, 1, 1},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 5, "Should find 5 tightly packed items")

  // Query for isolated item
  query_bounds = geometry.Aabb{
    min = {99, 99, 99},
    max = {101, 101, 101},
  }

  clear(&results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) >= 1, "Should find at least 1 isolated item")
  if len(results) > 0 {
    testing.expect(t, results[0].id == 6, "Should find the isolated item")
  }
}

@(test)
test_bvh_edge_cases :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  // Test with identical positions
  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 1),
    make_test_item(2, {0, 0, 0}, 1),
    make_test_item(3, {0, 0, 0}, 1),
  }

  geometry.bvh_build(&bvh, items)

  testing.expect(t, geometry.bvh_validate(&bvh), "BVH with identical positions should be valid")
  testing.expect(t, len(bvh.primitives) == 3, "Should have all 3 primitives")

  // Query should find all items
  query_bounds := geometry.Aabb{
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 3, "Should find all 3 items at same position")
}

@(test)
test_bvh_degenerate_cases :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  // Test with zero-volume items
  items := []BVHTestItem{
    make_test_item(1, {0, 0, 0}, 0),
    make_test_item(2, {1, 0, 0}, 0),
    make_test_item(3, {0, 1, 0}, 0),
  }

  geometry.bvh_build(&bvh, items)

  testing.expect(t, geometry.bvh_validate(&bvh), "BVH with zero-volume items should be valid")
  testing.expect(t, len(bvh.primitives) == 3, "Should have all 3 primitives")

  // Query should still work
  query_bounds := geometry.Aabb{
    min = {-0.5, -0.5, -0.5},
    max = {0.5, 0.5, 0.5},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 1, "Should find 1 zero-volume item")
  testing.expect(t, results[0].id == 1, "Should find the item at origin")
}

@(test)
test_bvh_memory_management :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  // Test multiple builds don't leak memory
  for iteration in 0..<3 {
    items := []BVHTestItem{
      make_test_item(1, {0, 0, 0}, 1),
      make_test_item(2, {1, 0, 0}, 1),
      make_test_item(3, {0, 1, 0}, 1),
    }

    geometry.bvh_build(&bvh, items)

    testing.expect(t, len(bvh.primitives) == 3, "Should have 3 primitives after rebuild")
    testing.expect(t, geometry.bvh_validate(&bvh), "BVH should be valid after rebuild")
  }
}

@(test)
test_bvh_precision :: proc(t: ^testing.T) {
  bvh: geometry.BVH(BVHTestItem)
  bvh.bounds_func = test_bvh_item_bounds
  defer geometry.bvh_deinit(&bvh)

  // Test with very small and very large coordinates
  items := []BVHTestItem{
    make_test_item(1, {0.0001, 0.0001, 0.0001}, 0.0001),
    make_test_item(2, {1000000, 1000000, 1000000}, 1000),
    make_test_item(3, {-1000000, -1000000, -1000000}, 1000),
  }

  geometry.bvh_build(&bvh, items)

  testing.expect(t, geometry.bvh_validate(&bvh), "BVH with extreme coordinates should be valid")
  testing.expect(t, len(bvh.primitives) == 3, "Should have all 3 primitives")

  // Query for small item
  query_bounds := geometry.Aabb{
    min = {0, 0, 0},
    max = {0.001, 0.001, 0.001},
  }

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  geometry.bvh_query_aabb(&bvh, query_bounds, &results)

  testing.expect(t, len(results) == 1, "Should find small item")
  testing.expect(t, results[0].id == 1, "Should find the small item")
}

@(test)
bvh_build_benchmark :: proc(t: ^testing.T) {
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    items_ptr := cast(^[]TestItem)raw_data(options.input)
    items := items_ptr^

    for _ in 0 ..< options.rounds {
      bvh: geometry.BVH(TestItem)
      bvh.bounds_func = test_item_bounds
      defer geometry.bvh_deinit(&bvh)

      geometry.bvh_build(&bvh, items)
      options.processed += len(items) * size_of(TestItem)
    }
    return nil
  }

  item_count := 100
  items := make([]TestItem, item_count)
  defer delete(items)

  for i in 0 ..< item_count {
    x := f32(i % 100 - 50) * 2
    y := f32((i / 100) % 100 - 50) * 2
    z := f32((i / 10000) % 100 - 50) * 2

    items[i] = TestItem {
      id   = i32(i),
      pos  = {x, y, z},
      size = 1.5,
    }
  }

  options := &time.Benchmark_Options {
    rounds = 2,
    bytes = item_count * size_of(TestItem) * 2,
    input = slice.bytes_from_ptr(&items, size_of([]TestItem)),
    bench = bench_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "BVH build: %d items built %d times in %v (%.2f MB/s) | %.2f ms/build",
    item_count,
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000000 / f64(options.rounds),
  )
}

@(test)
bvh_query_benchmark :: proc(t: ^testing.T) {
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(TestItem))
    bvh_ptr.bounds_func = test_item_bounds

    item_count := 15000
    items := make([]TestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 80 - 40) * 1.8
      y := f32((i / 80) % 80 - 40) * 1.8
      z := f32((i / 6400) % 80 - 40) * 1.8

      items[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 1.2,
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(TestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    results := make([dynamic]TestItem, 0, 100)
    defer delete(results)

    for i in 0 ..< options.rounds {
      offset := f32(i % 150 - 75) * 0.1
      query_bounds := geometry.Aabb {
        min = {-8 + offset, -8 + offset, -8 + offset},
        max = {8 + offset, 8 + offset, 8 + offset},
      }
      geometry.bvh_query_aabb(bvh_ptr, query_bounds, &results)
      options.processed += len(results) * size_of(TestItem)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 2000,
    bytes = size_of(TestItem) * 50 * 2000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "BVH query: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
bvh_ray_benchmark :: proc(t: ^testing.T) {
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(TestItem))
    bvh_ptr.bounds_func = test_item_bounds

    item_count := 12000
    items := make([]TestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 60 - 30) * 2.5
      y := f32((i / 60) % 60 - 30) * 2.5
      z := f32((i / 3600) % 60 - 30) * 2.5

      items[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 1.8,
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(TestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    results := make([dynamic]TestItem, 0, 50)
    defer delete(results)

    for i in 0 ..< options.rounds {
      angle := f32(i) * 0.001
      ray := geometry.Ray {
        origin = {-50 + f32(i % 100) * 0.1, -50 + f32(i % 100) * 0.1, -50},
        direction = {math.cos(angle), math.sin(angle), 0.8},
      }
      geometry.bvh_query_ray(bvh_ptr, ray, 200, &results)
      options.processed += len(results) * size_of(TestItem)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 15000,
    bytes = size_of(TestItem) * 30 * 15000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "BVH ray: %d rays in %v (%.2f MB/s) | %.2f μs/ray",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
bvh_nearest_benchmark :: proc(t: ^testing.T) {
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(TestItem))
    bvh_ptr.bounds_func = test_item_bounds

    item_count := 8000
    items := make([]TestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 40 - 20) * 3
      y := f32((i / 40) % 40 - 20) * 3
      z := f32((i / 1600) % 40 - 20) * 3

      items[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 2,
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(TestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)

    for i in 0 ..< options.rounds {
      query_point := [3]f32{
        f32(i % 80 - 40) * 0.8,
        f32((i / 80) % 80 - 40) * 0.8,
        f32((i / 6400) % 80 - 40) * 0.8,
      }
      _, _, found := geometry.bvh_query_nearest(bvh_ptr, query_point)
      if found {
        options.processed += size_of(TestItem)
      }
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 1000,
    bytes = size_of(TestItem) * 1000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "BVH nearest: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
bvh_empty_query_benchmark :: proc(t: ^testing.T) {
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(TestItem))
    bvh_ptr.bounds_func = test_item_bounds

    item_count := 5000
    items := make([]TestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 50 - 75) * 1.5
      y := f32((i / 50) % 50 - 75) * 1.5
      z := f32((i / 2500) % 50 - 75) * 1.5

      items[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 1,
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(TestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    results := make([dynamic]TestItem, 0, 50)
    defer delete(results)

    for i in 0 ..< options.rounds {
      offset := f32(i % 100 - 50) * 0.2
      empty_query_bounds := geometry.Aabb {
        min = {60 + offset, 60 + offset, 60 + offset},
        max = {80 + offset, 80 + offset, 80 + offset},
      }
      geometry.bvh_query_aabb(bvh_ptr, empty_query_bounds, &results)
      options.processed += len(results) * size_of(TestItem)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 1500,
    bytes = size_of(TestItem) * 0 * 1500,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "BVH empty query: %d queries in %v (%.2f MB/s) | %.2f μs/query",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000 / f64(options.rounds),
  )
}

@(test)
bvh_refit_benchmark :: proc(t: ^testing.T) {
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(geometry.BVH(TestItem))
    bvh_ptr.bounds_func = test_item_bounds

    item_count := 3000
    items := make([]TestItem, item_count)

    for i in 0 ..< item_count {
      x := f32(i % 30 - 15) * 4
      y := f32((i / 30) % 30 - 15) * 4
      z := f32((i / 900) % 30 - 15) * 4

      items[i] = TestItem {
        id   = i32(i),
        pos  = {x, y, z},
        size = 2.5,
      }
    }

    geometry.bvh_build(bvh_ptr, items)
    delete(items)

    options.input = slice.bytes_from_ptr(bvh_ptr, size_of(^geometry.BVH(TestItem)))
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)

    for i in 0 ..< options.rounds {
      random_offset := f32(i % 100 - 50) * 0.1
      for j in 0 ..< min(len(bvh_ptr.primitives), 100) {
        bvh_ptr.primitives[j].pos.x += random_offset
        bvh_ptr.primitives[j].pos.y += random_offset
      }

      geometry.bvh_refit(bvh_ptr)
      options.processed += len(bvh_ptr.primitives) * size_of(TestItem)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^geometry.BVH(TestItem))raw_data(options.input)
    geometry.bvh_deinit(bvh_ptr)
    free(bvh_ptr)
    return nil
  }

  options := &time.Benchmark_Options {
    rounds = 1000,
    bytes = size_of(TestItem) * 3000 * 1000,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }

  err := time.benchmark(options)
  log.infof(
    "BVH refit: %d refits in %v (%.2f MB/s) | %.2f ms/refit",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000000 / f64(options.rounds),
  )
}
