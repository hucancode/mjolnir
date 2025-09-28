package tests

import "core:log"
import "core:testing"
import "core:time"
import "../mjolnir/interval_tree"

@(test)
test_interval_tree_basic :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Test empty tree
  testing.expect(t, interval_tree.is_empty(&tree), "Tree should be empty initially")

  ranges := interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 0, "Empty tree should return no ranges")

  // Test single insertion
  interval_tree.insert(&tree, 5, 1)
  testing.expect(t, !interval_tree.is_empty(&tree), "Tree should not be empty after insertion")

  ranges = interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 1, "Should have exactly one range")
  testing.expect(t, ranges[0].start == 5 && ranges[0].end == 5, "Range should be [5, 5]")

  // Test clear
  interval_tree.clear(&tree)
  testing.expect(t, interval_tree.is_empty(&tree), "Tree should be empty after clear")
}

@(test)
test_interval_tree_range_insertion :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Test range insertion
  interval_tree.insert(&tree, 10, 5) // [10, 14]
  ranges := interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 1, "Should have one range")
  testing.expect(t, ranges[0].start == 10 && ranges[0].end == 14, "Range should be [10, 14]")

  // Test non-overlapping range
  interval_tree.insert(&tree, 20, 3) // [20, 22]
  ranges = interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 2, "Should have two ranges")

  // Verify ranges are sorted
  testing.expect(t, ranges[0].start == 10 && ranges[0].end == 14, "First range should be [10, 14]")
  testing.expect(t, ranges[1].start == 20 && ranges[1].end == 22, "Second range should be [20, 22]")
}

@(test)
test_interval_tree_merging :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Test overlapping intervals merge
  interval_tree.insert(&tree, 10, 5) // [10, 14]
  interval_tree.insert(&tree, 12, 5) // [12, 16] - overlaps with [10, 14]

  ranges := interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 1, "Overlapping ranges should merge")
  testing.expect(t, ranges[0].start == 10 && ranges[0].end == 16, "Merged range should be [10, 16]")

  // Test adjacent intervals merge
  interval_tree.clear(&tree)
  interval_tree.insert(&tree, 5, 3)  // [5, 7]
  interval_tree.insert(&tree, 8, 2)  // [8, 9] - adjacent to [5, 7]

  ranges = interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 1, "Adjacent ranges should merge")
  testing.expect(t, ranges[0].start == 5 && ranges[0].end == 9, "Merged range should be [5, 9]")
}

@(test)
test_interval_tree_complex_merging :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Create multiple separate ranges
  interval_tree.insert(&tree, 5, 1)   // [5, 5]
  interval_tree.insert(&tree, 15, 1)  // [15, 15]
  interval_tree.insert(&tree, 25, 1)  // [25, 25]

  ranges := interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 3, "Should have three separate ranges")

  // Insert range that connects them all
  interval_tree.insert(&tree, 4, 22)  // [4, 25] - covers all existing ranges

  ranges = interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 1, "All ranges should merge into one")
  testing.expect(t, ranges[0].start == 4 && ranges[0].end == 25, "Merged range should be [4, 25]")
}

@(test)
test_interval_tree_sparse_pattern :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Insert sparse individual elements
  sparse_indices := []int{1, 100, 1000, 5000, 10000}
  for idx in sparse_indices {
    interval_tree.insert(&tree, idx, 1)
  }

  ranges := interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == len(sparse_indices), "Should have one range per sparse element")

  // Verify all ranges are single elements
  for range_val, i in ranges {
    expected := sparse_indices[i]
    testing.expect(t, range_val.start == expected && range_val.end == expected,
      "Range should be single element")
  }
}

@(test)
test_interval_tree_performance :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Test performance with many ranges
  range_count := 1000
  range_size := 10

  start_time := time.now()
  for i in 0..<range_count {
    start := i * range_size * 2 // non-overlapping ranges
    interval_tree.insert(&tree, start, range_size)
  }
  insert_duration := time.since(start_time)

  ranges := interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == range_count, "Should have all ranges")

  start_time = time.now()
  interval_tree.get_ranges(&tree)
  get_duration := time.since(start_time)

  log.infof("Interval tree performance: %d ranges of size %d", range_count, range_size)
  log.infof("Insert time: %v", insert_duration)
  log.infof("Get ranges time: %v", get_duration)
}

@(test)
test_interval_tree_vs_dirty_set :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Simulate dirty buffer operations
  test_cases := []struct {
    name: string,
    operations: []struct {
      start, count: int,
    },
    expected_ranges: int,
  }{
    {
      "single_elements",
      {{5, 1}, {10, 1}, {15, 1}},
      3,
    },
    {
      "contiguous_range",
      {{10, 5}},
      1,
    },
    {
      "merging_ranges",
      {{10, 3}, {12, 3}}, // [10,12] + [12,14] -> [10,14]
      1,
    },
    {
      "adjacent_ranges",
      {{5, 3}, {8, 2}}, // [5,7] + [8,9] -> [5,9]
      1,
    },
  }

  for test_case in test_cases {
    interval_tree.clear(&tree)

    for op in test_case.operations {
      interval_tree.insert(&tree, op.start, op.count)
    }

    ranges := interval_tree.get_ranges(&tree)
    testing.expectf(t, len(ranges) == test_case.expected_ranges,
      "Test case '%s': expected %d ranges, got %d",
      test_case.name, test_case.expected_ranges, len(ranges))
  }
}

@(test)
test_interval_tree_edge_cases :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  tree: interval_tree.IntervalTree
  interval_tree.init(&tree)
  defer interval_tree.destroy(&tree)

  // Test zero count insertion
  interval_tree.insert(&tree, 10, 0)
  testing.expect(t, interval_tree.is_empty(&tree), "Zero count insertion should not add anything")

  // Test negative count
  interval_tree.insert(&tree, 10, -5)
  testing.expect(t, interval_tree.is_empty(&tree), "Negative count insertion should not add anything")

  // Test large range
  interval_tree.insert(&tree, 0, 100000)
  ranges := interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 1, "Should have one large range")
  testing.expect(t, ranges[0].start == 0 && ranges[0].end == 99999, "Range should be [0, 99999]")

  // Test insertion at boundaries
  interval_tree.clear(&tree)
  interval_tree.insert(&tree, 0, 1)    // [0, 0]
  interval_tree.insert(&tree, 1, 1)    // [1, 1] - adjacent

  ranges = interval_tree.get_ranges(&tree)
  testing.expect(t, len(ranges) == 1, "Adjacent ranges at boundary should merge")
  testing.expect(t, ranges[0].start == 0 && ranges[0].end == 1, "Merged range should be [0, 1]")
}