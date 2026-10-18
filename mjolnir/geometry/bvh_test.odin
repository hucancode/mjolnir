#+build !js
#+private
package geometry

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"
import "core:thread"

BVHTestItem :: struct {
  id:     i32,
  bounds: Aabb,
}

test_bounds :: proc(items: []BVHTestItem) -> []Aabb {
  bounds := make([]Aabb, len(items), context.temp_allocator)
  for item, i in items do bounds[i] = item.bounds
  return bounds
}

make_test_item :: proc(id: i32, center: [3]f32, size: f32) -> BVHTestItem {
  half_size := [3]f32{size, size, size} * 0.5
  return BVHTestItem {
    id = id,
    bounds = Aabb{min = center - half_size, max = center + half_size},
  }
}

@(test)
test_bvh_build_empty :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  empty_items: []BVHTestItem
  bvh_build(&bvh, empty_items, test_bounds(empty_items))
  testing.expect(t, len(bvh.nodes) == 0, "Empty BVH should have no nodes")
  testing.expect(
    t,
    len(bvh.primitives) == 0,
    "Empty BVH should have no primitives",
  )
}

@(test)
test_bvh_build_single_item :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  items := []BVHTestItem{make_test_item(1, {0, 0, 0}, 2)}
  bvh_build(&bvh, items, test_bounds(items))
  testing.expect(t, len(bvh.nodes) == 1, "Single item BVH should have 1 node")
  testing.expect(
    t,
    len(bvh.primitives) == 1,
    "Single item BVH should have 1 primitive",
  )
  testing.expect(
    t,
    bvh.nodes[0].count > 0,
    "Single item node should be a leaf",
  )
  testing.expect(
    t,
    bvh.nodes[0].count == 1,
    "Single item node should have 1 primitive",
  )
}

@(test)
test_bvh_build_multiple_items :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  items := []BVHTestItem {
    make_test_item(1, {-5, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, -5, 0}, 2),
    make_test_item(4, {0, 5, 0}, 2),
    make_test_item(5, {0, 0, -5}, 2),
    make_test_item(6, {0, 0, 5}, 2),
  }
  bvh_build(&bvh, items, test_bounds(items), 2)
  testing.expect(
    t,
    len(bvh.nodes) > 1,
    "Multiple items should create multiple nodes",
  )
  testing.expect(t, len(bvh.primitives) == 6, "Should have all 6 primitives")
  // Validate tree structure
  testing.expect(t, bvh_validate(&bvh), "BVH should be valid")
  stats := bvh_get_stats(&bvh)
  testing.expect(t, stats.total_nodes > 1, "Should have multiple nodes")
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
  testing.expect(t, stats.internal_nodes > 0, "Should have internal nodes")
  testing.expect(t, stats.total_primitives == 6, "Should have all primitives")
}

@(test)
test_bvh_query_aabb :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {10, 0, 0}, 2),
    make_test_item(3, {0, 10, 0}, 2),
    make_test_item(4, {0, 0, 10}, 2),
    make_test_item(5, {20, 20, 20}, 2),
  }
  bvh_build(&bvh, items, test_bounds(items))
  // Query near origin
  query_bounds := Aabb {
    min = {-5, -5, -5},
    max = {5, 5, 5},
  }
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) == 1, "Should find 1 item near origin")
  testing.expect(t, results[0].id == 1, "Should find the item at origin")
  // Query larger area
  query_bounds = Aabb {
    min = {-5, -5, -5},
    max = {15, 15, 15},
  }
  clear(&results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) == 4, "Should find 4 items in larger area")
  // Query empty area
  query_bounds = Aabb {
    min = {100, 100, 100},
    max = {200, 200, 200},
  }
  clear(&results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) == 0, "Should find no items in empty area")
}

@(test)
test_bvh_query_ray :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 5 * time.Second)
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {10, 0, 0}, 2),
    make_test_item(4, {0, 5, 0}, 2),
    make_test_item(5, {0, 0, 5}, 2),
  }
  bvh_build(&bvh, items, test_bounds(items))
  // Ray along X axis
  ray := Ray {
    origin    = {-10, 0, 0},
    direction = {1, 0, 0},
  }
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  bvh_query_ray(&bvh, ray, 20, &results)
  testing.expect(t, len(results) == 3, "Should find 3 items along X axis")
  // Ray along Y axis
  ray = Ray {
    origin    = {0, -10, 0},
    direction = {0, 1, 0},
  }
  clear(&results)
  bvh_query_ray(&bvh, ray, 20, &results)
  testing.expect(t, len(results) == 2, "Should find 2 items along Y axis")
  // Ray that misses everything
  ray = Ray {
    origin    = {100, 100, 100},
    direction = {1, 0, 0},
  }
  clear(&results)
  bvh_query_ray(&bvh, ray, 20, &results)
  testing.expect(
    t,
    len(results) == 0,
    "Should find no items for ray that misses",
  )
}

@(test)
test_bvh_matches_brute_force :: proc(t: ^testing.T) {
  rand.reset(7)
  make_items :: proc(n: int, spread: f32) -> []BVHTestItem {
    items := make([]BVHTestItem, n)
    for &item, i in items {
      c := [3]f32{rand.float32_range(-spread, spread), rand.float32_range(-spread, spread), rand.float32_range(-spread, spread)}
      item = make_test_item(i32(i), c, rand.float32_range(0.5, 6))
    }
    return items
  }
  items_a, items_b := make_items(700, 40), make_items(300, 40)
  defer delete(items_a)
  defer delete(items_b)
  a, b: BVH(BVHTestItem)
  defer bvh_destroy(&a)
  defer bvh_destroy(&b)
  bvh_build(&a, items_a, test_bounds(items_a))
  bvh_build(&b, items_b, test_bounds(items_b), 1)
  testing.expect(t, bvh_validate(&a) && bvh_validate(&b))

  self_pairs := make([dynamic]BVHOverlapPair(BVHTestItem))
  defer delete(self_pairs)
  bvh_find_all_overlaps(&a, &self_pairs)
  expected := 0
  for i in 0 ..< len(items_a) do for j in i + 1 ..< len(items_a) {
    if aabb_intersects(items_a[i].bounds, items_a[j].bounds) do expected += 1
  }
  testing.expect_value(t, len(self_pairs), expected)
  seen := make(map[[2]i32]bool)
  defer delete(seen)
  for p in self_pairs {
    key := [2]i32{min(p.a.id, p.b.id), max(p.a.id, p.b.id)}
    testing.expect(t, key not_in seen, "pair reported twice")
    seen[key] = true
  }

  cross := make([dynamic]BVHCrossPair(BVHTestItem, BVHTestItem))
  defer delete(cross)
  bvh_find_cross_overlaps(&a, &b, &cross)
  expected = 0
  for x in items_a do for y in items_b {
    if aabb_intersects(x.bounds, y.bounds) do expected += 1
  }
  testing.expect_value(t, len(cross), expected)

  results := make([dynamic]BVHTestItem)
  defer delete(results)
  for _ in 0 ..< 50 {
    c := [3]f32{rand.float32_range(-40, 40), rand.float32_range(-40, 40), rand.float32_range(-40, 40)}
    q := Aabb{c - 5, c + 5}
    bvh_query_aabb(&a, q, &results)
    expected = 0
    for x in items_a do if aabb_intersects(x.bounds, q) do expected += 1
    testing.expect_value(t, len(results), expected)
    dir := linalg.normalize([3]f32{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)})
    bvh_query_ray(&a, Ray{origin = c, direction = dir}, 30, &results)
    expected = 0
    for x in items_a {
      inv := 1 / dir
      t1, t2 := (x.bounds.min - c) * inv, (x.bounds.max - c) * inv
      lo, hi := linalg.min(t1, t2), linalg.max(t1, t2)
      near, far := max(lo.x, lo.y, lo.z), min(hi.x, hi.y, hi.z)
      if near <= far && near <= 30 && far >= 0 do expected += 1
    }
    testing.expect_value(t, len(results), expected)
  }
}

@(test)
test_bvh_refit :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, 5, 0}, 2),
  }
  bvh_build(&bvh, items, test_bounds(items))
  // Store original root bounds
  original_bounds := bvh.nodes[0].bounds
  // Modify primitives
  bvh.bounds[0] = make_test_item(1, {10, 10, 10}, 2).bounds
  bvh.bounds[1] = make_test_item(2, {15, 0, 0}, 2).bounds
  // Refit the tree
  bvh_refit(&bvh)
  // Check that bounds have been updated
  new_bounds := bvh.nodes[0].bounds
  testing.expect(
    t,
    new_bounds.min != original_bounds.min ||
    new_bounds.max != original_bounds.max,
    "Root bounds should have changed after refit",
  )
  // Tree should still be valid
  testing.expect(
    t,
    bvh_validate(&bvh),
    "BVH should still be valid after refit",
  )
}

@(test)
test_bvh_validate :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, 5, 0}, 2),
    make_test_item(4, {0, 0, 5}, 2),
  }
  bvh_build(&bvh, items, test_bounds(items))
  // Valid tree should pass validation
  valid := bvh_validate(&bvh)
  testing.expect(t, valid, "Properly built BVH should be valid")
  // Corrupt the tree and check it fails validation
  if len(bvh.nodes) > 0 {
    original_count := bvh.nodes[0].count
    bvh.nodes[0].count = -1
    corrupted_valid := bvh_validate(&bvh)
    testing.expect(t, !corrupted_valid, "Corrupted BVH should fail validation")
    bvh.nodes[0].count = original_count
  }
}

@(test)
test_bvh_stats :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 2),
    make_test_item(2, {5, 0, 0}, 2),
    make_test_item(3, {0, 5, 0}, 2),
    make_test_item(4, {0, 0, 5}, 2),
    make_test_item(5, {10, 10, 10}, 2),
  }
  bvh_build(&bvh, items, test_bounds(items), 2)
  stats := bvh_get_stats(&bvh)
  testing.expect(t, stats.total_nodes > 0, "Should have nodes")
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
  testing.expect(t, stats.total_primitives == 5, "Should have all primitives")
  testing.expect(
    t,
    stats.max_leaf_size <= 2,
    "Max leaf size should respect limit",
  )
  testing.expect(
    t,
    stats.total_nodes == stats.leaf_nodes + stats.internal_nodes,
    "Total nodes should equal leaf + internal nodes",
  )
}

@(test)
test_bvh_large_dataset :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  // Create a large dataset
  item_count := 1000
  items := make([]BVHTestItem, item_count)
  defer delete(items)
  for i in 0 ..< item_count {
    x := f32(i % 10) * 2 - 10
    y := f32((i / 10) % 10) * 2 - 10
    z := f32((i / 100) % 10) * 2 - 10
    items[i] = make_test_item(i32(i), {x, y, z}, 1)
  }
  bvh_build(&bvh, items, test_bounds(items))
  // Verify all items are in the BVH
  testing.expect(t, len(bvh.primitives) == item_count, "Should have all items")
  testing.expect(t, bvh_validate(&bvh), "Large BVH should be valid")
  // Query a small region and verify performance
  query_bounds := Aabb {
    min = {-2, -2, -2},
    max = {2, 2, 2},
  }
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) > 0, "Should find items in query region")
  testing.expect(t, len(results) < item_count, "Should not find all items")
  // Verify found items are actually in the query region
  for item in results {
    testing.expect(
      t,
      aabb_intersects(item.bounds, query_bounds),
      "All found items should intersect query bounds",
    )
  }
  stats := bvh_get_stats(&bvh)
  testing.expect(
    t,
    stats.total_nodes > 1,
    "Large dataset should create multiple nodes",
  )
  testing.expect(t, stats.leaf_nodes > 0, "Should have leaf nodes")
  testing.expect(t, stats.internal_nodes > 0, "Should have internal nodes")
}

@(test)
test_bvh_sah_splitting :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  // Create items that should benefit from SAH splitting
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 1),
    make_test_item(2, {1, 0, 0}, 1),
    make_test_item(3, {2, 0, 0}, 1),
    make_test_item(4, {3, 0, 0}, 1),
    make_test_item(5, {4, 0, 0}, 1),
    make_test_item(6, {100, 100, 100}, 1),
  }
  bvh_build(&bvh, items, test_bounds(items), 2)
  testing.expect(
    t,
    bvh_validate(&bvh),
    "SAH-built BVH should be valid",
  )
  // Query for tightly packed items
  query_bounds := Aabb {
    min = {-1, -1, -1},
    max = {5, 1, 1},
  }
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) == 5, "Should find 5 tightly packed items")
  // Query for isolated item
  query_bounds = Aabb {
    min = {99, 99, 99},
    max = {101, 101, 101},
  }
  clear(&results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) >= 1, "Should find at least 1 isolated item")
  if len(results) > 0 {
    testing.expect(t, results[0].id == 6, "Should find the isolated item")
  }
}

@(test)
test_bvh_edge_cases :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  // Test with identical positions
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 1),
    make_test_item(2, {0, 0, 0}, 1),
    make_test_item(3, {0, 0, 0}, 1),
  }
  bvh_build(&bvh, items, test_bounds(items))
  testing.expect(
    t,
    bvh_validate(&bvh),
    "BVH with identical positions should be valid",
  )
  testing.expect(t, len(bvh.primitives) == 3, "Should have all 3 primitives")
  // Query should find all items
  query_bounds := Aabb {
    min = {-1, -1, -1},
    max = {1, 1, 1},
  }
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(
    t,
    len(results) == 3,
    "Should find all 3 items at same position",
  )
}

@(test)
test_bvh_degenerate_cases :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  // Test with zero-volume items
  items := []BVHTestItem {
    make_test_item(1, {0, 0, 0}, 0),
    make_test_item(2, {1, 0, 0}, 0),
    make_test_item(3, {0, 1, 0}, 0),
  }
  bvh_build(&bvh, items, test_bounds(items))
  testing.expect(
    t,
    bvh_validate(&bvh),
    "BVH with zero-volume items should be valid",
  )
  testing.expect(t, len(bvh.primitives) == 3, "Should have all 3 primitives")
  // Query should still work
  query_bounds := Aabb {
    min = {-0.5, -0.5, -0.5},
    max = {0.5, 0.5, 0.5},
  }
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) == 1, "Should find 1 zero-volume item")
  testing.expect(t, results[0].id == 1, "Should find the item at origin")
}

@(test)
test_bvh_memory_management :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  // Test multiple builds don't leak memory
  for _ in 0 ..< 3 {
    items := []BVHTestItem {
      make_test_item(1, {0, 0, 0}, 1),
      make_test_item(2, {1, 0, 0}, 1),
      make_test_item(3, {0, 1, 0}, 1),
    }
    bvh_build(&bvh, items, test_bounds(items))
    testing.expect(
      t,
      len(bvh.primitives) == 3,
      "Should have 3 primitives after rebuild",
    )
    testing.expect(
      t,
      bvh_validate(&bvh),
      "BVH should be valid after rebuild",
    )
  }
}

@(test)
test_bvh_precision :: proc(t: ^testing.T) {
  bvh: BVH(BVHTestItem)
  defer bvh_destroy(&bvh)
  // Test with very small and very large coordinates
  items := []BVHTestItem {
    make_test_item(1, {0.0001, 0.0001, 0.0001}, 0.0001),
    make_test_item(2, {1000000, 1000000, 1000000}, 1000),
    make_test_item(3, {-1000000, -1000000, -1000000}, 1000),
  }
  bvh_build(&bvh, items, test_bounds(items))
  testing.expect(
    t,
    bvh_validate(&bvh),
    "BVH with extreme coordinates should be valid",
  )
  testing.expect(t, len(bvh.primitives) == 3, "Should have all 3 primitives")
  // Query for small item
  query_bounds := Aabb {
    min = {0, 0, 0},
    max = {0.001, 0.001, 0.001},
  }
  results := make([dynamic]BVHTestItem)
  defer delete(results)
  bvh_query_aabb(&bvh, query_bounds, &results)
  testing.expect(t, len(results) == 1, "Should find small item")
  testing.expect(t, results[0].id == 1, "Should find the small item")
}

@(test)
bvh_build_benchmark :: proc(t: ^testing.T) {
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    items_ptr := cast(^[]BVHTestItem)raw_data(options.input)
    items := items_ptr^
    for _ in 0 ..< options.rounds {
      bvh: BVH(BVHTestItem)
      defer bvh_destroy(&bvh)
      bvh_build(&bvh, items, test_bounds(items))
      options.processed += len(items) * size_of(BVHTestItem)
    }
    return nil
  }
  item_count := 100000
  items := make([]BVHTestItem, item_count)
  defer delete(items)
  // Generate items in a large cube for realistic distribution
  cube_size := 200
  for i in 0 ..< item_count {
    x := f32(i % cube_size - cube_size / 2) * 2
    y := f32((i / cube_size) % cube_size - cube_size / 2) * 2
    z := f32((i / (cube_size * cube_size)) % cube_size - cube_size / 2) * 2
    items[i] = make_test_item(i32(i), {x, y, z}, 1.5)
  }
  options := &time.Benchmark_Options {
    rounds = 3,
    bytes = item_count * size_of(BVHTestItem) * 3,
    input = slice.bytes_from_ptr(&items, size_of([]BVHTestItem)),
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
  testing.set_fail_timeout(t, 15 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(BVH(BVHTestItem))
    item_count := 50000
    items := make([]BVHTestItem, item_count)
    for i in 0 ..< item_count {
      x := f32(i % 200 - 100) * 1.8
      y := f32((i / 200) % 200 - 100) * 1.8
      z := f32((i / 40000) % 200 - 100) * 1.8
      items[i] = make_test_item(i32(i), {x, y, z}, 1.2)
    }
    bvh_build(bvh_ptr, items, test_bounds(items))
    delete(items)
    options.input = slice.bytes_from_ptr(
      bvh_ptr,
      size_of(^BVH(BVHTestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    results := make([dynamic]BVHTestItem, 0, 100)
    defer delete(results)
    for i in 0 ..< options.rounds {
      offset := f32(i % 150 - 75) * 0.1
      query_bounds := Aabb {
        min = {-8 + offset, -8 + offset, -8 + offset},
        max = {8 + offset, 8 + offset, 8 + offset},
      }
      bvh_query_aabb(bvh_ptr, query_bounds, &results)
      options.processed += len(results) * size_of(BVHTestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    bvh_destroy(bvh_ptr)
    free(bvh_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = 10000,
    bytes = size_of(BVHTestItem) * 50 * 10000,
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
  testing.set_fail_timeout(t, 15 * time.Second)
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := new(BVH(BVHTestItem))
    item_count := 50000
    items := make([]BVHTestItem, item_count)
    for i in 0 ..< item_count {
      x := f32(i % 60 - 30) * 2.5
      y := f32((i / 60) % 60 - 30) * 2.5
      z := f32((i / 3600) % 60 - 30) * 2.5
      items[i] = make_test_item(i32(i), {x, y, z}, 1.8)
    }
    bvh_build(bvh_ptr, items, test_bounds(items))
    delete(items)
    options.input = slice.bytes_from_ptr(
      bvh_ptr,
      size_of(^BVH(BVHTestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    results := make([dynamic]BVHTestItem, 0, 50)
    defer delete(results)
    for i in 0 ..< options.rounds {
      angle := f32(i) * 0.001
      ray := Ray {
        origin    = {-50 + f32(i % 100) * 0.1, -50 + f32(i % 100) * 0.1, -50},
        direction = {math.cos(angle), math.sin(angle), 0.8},
      }
      bvh_query_ray(bvh_ptr, ray, 200, &results)
      options.processed += len(results) * size_of(BVHTestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    bvh_destroy(bvh_ptr)
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
    "BVH ray: %d rays in %v (%.2f MB/s) | %.2f μs/ray",
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
    bvh_ptr := new(BVH(BVHTestItem))
    item_count := 5000
    items := make([]BVHTestItem, item_count)
    for i in 0 ..< item_count {
      x := f32(i % 50 - 75) * 1.5
      y := f32((i / 50) % 50 - 75) * 1.5
      z := f32((i / 2500) % 50 - 75) * 1.5
      items[i] = make_test_item(i32(i), {x, y, z}, 1)
    }
    bvh_build(bvh_ptr, items, test_bounds(items))
    delete(items)
    options.input = slice.bytes_from_ptr(
      bvh_ptr,
      size_of(^BVH(BVHTestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    results := make([dynamic]BVHTestItem, 0, 50)
    defer delete(results)
    for i in 0 ..< options.rounds {
      offset := f32(i % 100 - 50) * 0.2
      empty_query_bounds := Aabb {
        min = {60 + offset, 60 + offset, 60 + offset},
        max = {80 + offset, 80 + offset, 80 + offset},
      }
      bvh_query_aabb(bvh_ptr, empty_query_bounds, &results)
      options.processed += len(results) * size_of(BVHTestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    bvh_destroy(bvh_ptr)
    free(bvh_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = 1500,
    bytes = size_of(BVHTestItem) * 0 * 1500,
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
    bvh_ptr := new(BVH(BVHTestItem))
    item_count := 3000
    items := make([]BVHTestItem, item_count)
    for i in 0 ..< item_count {
      x := f32(i % 30 - 15) * 4
      y := f32((i / 30) % 30 - 15) * 4
      z := f32((i / 900) % 30 - 15) * 4
      items[i] = make_test_item(i32(i), {x, y, z}, 2.5)
    }
    bvh_build(bvh_ptr, items, test_bounds(items))
    delete(items)
    options.input = slice.bytes_from_ptr(
      bvh_ptr,
      size_of(^BVH(BVHTestItem)),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    for i in 0 ..< options.rounds {
      random_offset := f32(i % 100 - 50) * 0.1
      for j in 0 ..< min(len(bvh_ptr.primitives), 100) {
        bvh_ptr.bounds[j].min.x += random_offset
        bvh_ptr.bounds[j].min.y += random_offset
        bvh_ptr.bounds[j].max.x += random_offset
        bvh_ptr.bounds[j].max.y += random_offset
      }
      bvh_refit(bvh_ptr)
      options.processed += len(bvh_ptr.primitives) * size_of(BVHTestItem)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    bvh_ptr := cast(^BVH(BVHTestItem))raw_data(options.input)
    bvh_destroy(bvh_ptr)
    free(bvh_ptr)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = 1000,
    bytes = size_of(BVHTestItem) * 3000 * 1000,
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

@(test)
bvh_build_sequential_benchmark :: proc(t: ^testing.T) {
  N :: 20000
  ROUNDS :: 5
  testing.set_fail_timeout(t, 30 * time.Second)
  BuildInput :: struct {
    items: []BVHTestItem,
  }
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    input := new(BuildInput)
    input.items = make([]BVHTestItem, N)
    for i in 0 ..< len(input.items) {
      x := f32(i % 200 - 100) * 2
      y := f32((i / 200) % 200 - 100) * 2
      z := f32((i / 40000) % 200 - 100) * 2
      input.items[i] = make_test_item(i32(i), {x, y, z}, 1.5)
    }
    options.input = slice.bytes_from_ptr(
      input,
      size_of(^BuildInput),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    input := cast(^BuildInput)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      bvh: BVH(BVHTestItem)
      bvh_build(&bvh, input.items, test_bounds(input.items))
      options.processed += len(input.items) * size_of(BVHTestItem)
      bvh_destroy(&bvh)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    input := cast(^BuildInput)raw_data(options.input)
    delete(input.items)
    free(input)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = ROUNDS,
    bytes = size_of(BVHTestItem) * N * ROUNDS,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }
  _ = time.benchmark(options)
  log.infof(
    "BVH sequential build: %d items built %d times in %v (%.2f MB/s) | %.2f ms/build",
    N,
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000000 / f64(options.rounds),
  )
}

@(test)
bvh_build_parallel_benchmark :: proc(t: ^testing.T) {
  N :: 20000
  ROUNDS :: 5
  testing.set_fail_timeout(t, 30 * time.Second)
  BuildParallelInput :: struct {
    items: []BVHTestItem,
    pool:  thread.Pool,
  }
  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    input := new(BuildParallelInput)
    input.items = make([]BVHTestItem, N)
    for i in 0 ..< len(input.items) {
      x := f32(i % 200 - 100) * 2
      y := f32((i / 200) % 200 - 100) * 2
      z := f32((i / 40000) % 200 - 100) * 2
      input.items[i] = make_test_item(i32(i), {x, y, z}, 1.5)
    }
    thread.pool_init(&input.pool, context.allocator, 16)
    thread.pool_start(&input.pool)
    options.input = slice.bytes_from_ptr(
      input,
      size_of(^BuildParallelInput),
    )
    return nil
  }
  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    input := cast(^BuildParallelInput)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      bvh: BVH(BVHTestItem)
      bvh_build_parallel(&bvh, input.items, test_bounds(input.items), &input.pool)
      options.processed += len(input.items) * size_of(BVHTestItem)
      bvh_destroy(&bvh)
    }
    return nil
  }
  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    input := cast(^BuildParallelInput)raw_data(options.input)
    thread.pool_join(&input.pool)
    thread.pool_destroy(&input.pool)
    delete(input.items)
    free(input)
    return nil
  }
  options := &time.Benchmark_Options {
    rounds = ROUNDS,
    bytes = size_of(BVHTestItem) * N * ROUNDS,
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
  }
  _ = time.benchmark(options)
  log.infof(
    "BVH parallel build: %d items built %d times in %v (%.2f MB/s) | %.2f ms/build",
    N,
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    f64(options.duration) / 1000000 / f64(options.rounds),
  )
}

// Structural invariants of a built BVH.
@(private = "file")
bvh_validate :: proc(self: ^BVH($T)) -> bool {
  if len(self.nodes) == 0 do return true
  for node, i in self.nodes {
    if node.count == 0 {
      if node.offset <= i32(i) + 1 || node.offset >= i32(len(self.nodes)) do return false
      left := self.nodes[i + 1]
      right := self.nodes[node.offset]
      if !aabb_contains_approx(node.bounds, left.bounds, 1e-3) do return false
      if !aabb_contains_approx(node.bounds, right.bounds, 1e-3) do return false
    } else {
      if node.count < 0 || node.offset < 0 do return false
      if node.offset + node.count > i32(len(self.primitives)) do return false
    }
  }
  return len(self.bounds) == len(self.primitives)
}

@(private = "file")
aabb_contains_approx :: proc "contextless" (
  outer, inner: Aabb,
  epsilon: f32 = 1e-6,
) -> bool {
  return(
    inner.min.x >= outer.min.x - epsilon &&
    inner.max.x <= outer.max.x + epsilon &&
    inner.min.y >= outer.min.y - epsilon &&
    inner.max.y <= outer.max.y + epsilon &&
    inner.min.z >= outer.min.z - epsilon &&
    inner.max.z <= outer.max.z + epsilon \
  )
}

@(private = "file")
BVHStats :: struct {
  total_nodes:      i32,
  leaf_nodes:       i32,
  internal_nodes:   i32,
  total_primitives: i32,
  max_leaf_size:    i32,
}

@(private = "file")
bvh_get_stats :: proc(self: ^BVH($T)) -> BVHStats {
  stats: BVHStats
  for node in self.nodes {
    stats.total_nodes += 1
    if node.count > 0 {
      stats.leaf_nodes += 1
      stats.total_primitives += node.count
      stats.max_leaf_size = max(stats.max_leaf_size, node.count)
    } else {
      stats.internal_nodes += 1
    }
  }
  return stats
}
