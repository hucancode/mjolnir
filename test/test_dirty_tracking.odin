package tests

import "core:log"
import "core:slice"
import "core:testing"
import "core:time"
import "../mjolnir/gpu"

@(test)
test_dirty_set_basic :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  ds: gpu.DirtySet
  gpu.dirty_set_init(&ds)
  defer gpu.dirty_set_destroy(&ds)
  // Test adding single index
  gpu.dirty_set_add(&ds, 5)
  testing.expect(t, len(ds.indices) == 1, "Should have exactly one element")
  testing.expect(t, ds.indices[0] == 5, "First element should be 5")

  // Test adding duplicate index
  gpu.dirty_set_add(&ds, 5)
  testing.expect(t, len(ds.indices) == 1, "Duplicate should not be added")

  // Test adding more indices in sorted order
  gpu.dirty_set_add(&ds, 10)
  gpu.dirty_set_add(&ds, 3)
  gpu.dirty_set_add(&ds, 7)

  expected := []int{3, 5, 7, 10}
  testing.expect(t, len(ds.indices) == len(expected), "Should have 4 elements")
  for i in 0..<len(expected) {
    testing.expect(t, ds.indices[i] == expected[i], "Elements should be sorted")
  }

  // Test clear
  gpu.dirty_set_clear(&ds)
  testing.expect(t, len(ds.indices) == 0, "Set should be empty after clear")
}

@(test)
test_dirty_set_range :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  ds: gpu.DirtySet
  gpu.dirty_set_init(&ds)
  defer gpu.dirty_set_destroy(&ds)

  // Test adding range
  gpu.dirty_set_add_range(&ds, 10, 5)
  expected := []int{10, 11, 12, 13, 14}
  testing.expect(t, len(ds.indices) == len(expected), "Should have 5 elements")
  for i in 0..<len(expected) {
    testing.expect(t, ds.indices[i] == expected[i], "Range elements should be correct")
  }

  // Test adding overlapping range
  gpu.dirty_set_add_range(&ds, 12, 4)
  expected_after_overlap := []int{10, 11, 12, 13, 14, 15}
  testing.expect(t, len(ds.indices) == len(expected_after_overlap), "Should have 6 elements after overlap")
  for i in 0..<len(expected_after_overlap) {
    testing.expect(t, ds.indices[i] == expected_after_overlap[i], "Elements should be sorted after overlap")
  }
}

@(test)
test_dirty_set_range_complex :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  ds: gpu.DirtySet
  gpu.dirty_set_init(&ds)
  defer gpu.dirty_set_destroy(&ds)

  // Start with some existing indices
  gpu.dirty_set_add(&ds, 5)
  gpu.dirty_set_add(&ds, 15)
  gpu.dirty_set_add(&ds, 25)

  // Add range that overlaps with existing indices
  gpu.dirty_set_add_range(&ds, 14, 4) // adds 14, 15, 16, 17

  expected := []int{5, 14, 15, 16, 17, 25}
  testing.expect(t, len(ds.indices) == len(expected), "Should have 6 elements")
  for i in 0..<len(expected) {
    testing.expect(t, ds.indices[i] == expected[i], "Elements should be sorted correctly")
  }

  // Add range at beginning
  gpu.dirty_set_add_range(&ds, 1, 3) // adds 1, 2, 3

  expected_after_prepend := []int{1, 2, 3, 5, 14, 15, 16, 17, 25}
  testing.expect(t, len(ds.indices) == len(expected_after_prepend), "Should have 9 elements")
  for i in 0..<len(expected_after_prepend) {
    testing.expect(t, ds.indices[i] == expected_after_prepend[i], "Elements should be sorted after prepend")
  }

  // Add range at end
  gpu.dirty_set_add_range(&ds, 30, 2) // adds 30, 31

  expected_final := []int{1, 2, 3, 5, 14, 15, 16, 17, 25, 30, 31}
  testing.expect(t, len(ds.indices) == len(expected_final), "Should have 11 elements")
  for i in 0..<len(expected_final) {
    testing.expect(t, ds.indices[i] == expected_final[i], "Elements should be sorted after append")
  }
}

@(test)
test_dirty_set_range_performance :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  // Compare old naive approach vs optimized range insertion
  range_size := 1000
  num_ranges := 100

  // Test naive approach (adding one by one)
  ds1: gpu.DirtySet
  gpu.dirty_set_init(&ds1)
  defer gpu.dirty_set_destroy(&ds1)

  start_time := time.now()
  for i in 0..<num_ranges {
    start := i * range_size * 2 // non-overlapping ranges
    for j in 0..<range_size {
      gpu.dirty_set_add(&ds1, start + j)
    }
  }
  naive_duration := time.since(start_time)

  // Test optimized range insertion
  ds2: gpu.DirtySet
  gpu.dirty_set_init(&ds2)
  defer gpu.dirty_set_destroy(&ds2)

  start_time = time.now()
  for i in 0..<num_ranges {
    start := i * range_size * 2 // non-overlapping ranges
    gpu.dirty_set_add_range(&ds2, start, range_size)
  }
  optimized_duration := time.since(start_time)

  // Verify both produce same result
  testing.expect(t, len(ds1.indices) == len(ds2.indices), "Both approaches should produce same number of indices")
  for i in 0..<len(ds1.indices) {
    testing.expect(t, ds1.indices[i] == ds2.indices[i], "Indices should match")
  }

  speedup := f64(naive_duration) / f64(optimized_duration)
  log.infof("Range insertion test: %d ranges of %d elements each", num_ranges, range_size)
  log.infof("Naive approach: %v", naive_duration)
  log.infof("Optimized range: %v", optimized_duration)
  log.infof("Speedup: %.2fx", speedup)

  testing.expect(t, speedup > 1.0, "Optimized range insertion should be faster")
}

@(test)
test_dirty_set_performance :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  ds: gpu.DirtySet
  gpu.dirty_set_init(&ds)
  defer gpu.dirty_set_destroy(&ds)

  // Test performance with many sparse indices
  sparse_indices := []int{1, 100, 1000, 5000, 10000, 50000}

  start_time := time.now()
  for idx in sparse_indices {
    gpu.dirty_set_add(&ds, idx)
  }
  add_duration := time.since(start_time)

  testing.expect(t, len(ds.indices) == len(sparse_indices), "Should have all sparse indices")

  // Verify they're sorted
  for i in 1..<len(ds.indices) {
    testing.expect(t, ds.indices[i-1] < ds.indices[i], "Indices should be sorted")
  }

  log.infof("Adding %d sparse indices took %v", len(sparse_indices), add_duration)
}

// Helper to simulate old O(n) behavior for comparison
old_style_find_ranges :: proc(dirty_flags: []bool) -> int {
  regions := 0
  in_range := false

  for i in 0..=len(dirty_flags) {
    is_dirty := i < len(dirty_flags) && dirty_flags[i]
    if is_dirty && !in_range {
      in_range = true
    } else if !is_dirty && in_range {
      regions += 1
      in_range = false
    }
  }
  return regions
}

// Helper to simulate new O(d) behavior
new_style_find_ranges :: proc(dirty_indices: []int) -> int {
  if len(dirty_indices) == 0 do return 0

  regions := 0
  i := 0
  for i < len(dirty_indices) {
    // Find end of contiguous range
    for i + 1 < len(dirty_indices) && dirty_indices[i + 1] == dirty_indices[i] + 1 {
      i += 1
    }
    regions += 1
    i += 1
  }
  return regions
}

@(test)
test_flush_algorithm_correctness :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  // Test various dirty patterns to ensure both algorithms give same results
  test_cases := []struct {
    name: string,
    dirty_indices: []int,
    buffer_size: int,
  }{
    {"single_element", {5}, 10},
    {"contiguous_range", {3, 4, 5, 6}, 10},
    {"two_separate_ranges", {1, 2, 7, 8, 9}, 10},
    {"sparse_elements", {0, 3, 7, 9}, 10},
    {"full_buffer", {0, 1, 2, 3, 4, 5, 6, 7, 8, 9}, 10},
  }

  for test_case in test_cases {
    // Create old-style boolean array
    old_dirty := make([]bool, test_case.buffer_size)
    defer delete(old_dirty)

    for idx in test_case.dirty_indices {
      old_dirty[idx] = true
    }

    old_regions := old_style_find_ranges(old_dirty)
    new_regions := new_style_find_ranges(test_case.dirty_indices)

    testing.expectf(t, old_regions == new_regions,
      "Test case '%s': old algorithm found %d regions, new algorithm found %d regions",
      test_case.name, old_regions, new_regions)
  }
}

@(test)
test_flush_algorithm_performance :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  // Test performance difference between old O(n) and new O(d) algorithms
  buffer_size := 100000
  num_dirty := 100 // Only 100 dirty out of 100k elements

  // Create sparse dirty pattern
  dirty_indices := make([]int, num_dirty)
  defer delete(dirty_indices)

  old_dirty := make([]bool, buffer_size)
  defer delete(old_dirty)

  // Create sparse pattern - every 1000th element is dirty
  for i in 0..<num_dirty {
    idx := i * 1000
    dirty_indices[i] = idx
    old_dirty[idx] = true
  }

  // Time old algorithm (O(n))
  start_time := time.now()
  old_regions := old_style_find_ranges(old_dirty)
  old_duration := time.since(start_time)

  // Time new algorithm (O(d))
  start_time = time.now()
  new_regions := new_style_find_ranges(dirty_indices)
  new_duration := time.since(start_time)

  testing.expect(t, old_regions == new_regions, "Both algorithms should find same number of regions")

  log.infof("Buffer size: %d, Dirty elements: %d", buffer_size, num_dirty)
  log.infof("Old O(n) algorithm: %v", old_duration)
  log.infof("New O(d) algorithm: %v", new_duration)
  log.infof("Speedup: %.2fx", f64(old_duration) / f64(new_duration))

  // New algorithm should be significantly faster for sparse dirty patterns
  speedup := f64(old_duration) / f64(new_duration)
  testing.expect(t, speedup > 1.0, "New algorithm should be faster for sparse patterns")
}
