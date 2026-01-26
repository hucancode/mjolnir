package containers

import "core:testing"

// Test data structure
Test_Item :: struct {
  value: int,
  name:  string,
}

@(test)
test_pool_init :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool)
  defer destroy(pool, proc(item: ^Test_Item) {})

  testing.expect(t, len(pool.entries) == 0, "Pool should start empty")
  testing.expect(t, pool.capacity == 0, "Default capacity should be unlimited")
}

@(test)
test_pool_alloc_and_get :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool)
  defer destroy(pool, proc(item: ^Test_Item) {})

  // Allocate first item
  h1, item1, ok1 := alloc(&pool, Handle)
  testing.expect(t, ok1, "First allocation should succeed")
  testing.expect(t, h1.index == 0, "First handle index should be 0")
  testing.expect(t, h1.generation == 1, "First handle generation should be 1")

  // Set data
  item1.value = 42
  item1.name = "test"

  // Retrieve via handle
  retrieved, found := get(pool, h1)
  testing.expect(t, found, "Should find item by handle")
  testing.expect(t, retrieved.value == 42, "Should retrieve correct value")
  testing.expect(t, retrieved.name == "test", "Should retrieve correct name")
}

@(test)
test_pool_free_and_reuse :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool)
  defer destroy(pool, proc(item: ^Test_Item) {})

  // Allocate and free
  h1, item1, _ := alloc(&pool, Handle)
  item1.value = 100
  freed_item, freed := free(&pool, h1)
  testing.expect(t, freed, "Should successfully free item")
  testing.expect(
    t,
    freed_item.value == 100,
    "Should return pointer to freed item",
  )

  // Old handle should now be invalid
  _, found := get(pool, h1)
  testing.expect(t, !found, "Old handle should be invalid after free")

  // Allocate again - should reuse slot 0
  h2, item2, ok := alloc(&pool, Handle)
  testing.expect(t, ok, "Second allocation should succeed")
  testing.expect(t, h2.index == 0, "Should reuse index 0")
  testing.expect(t, h2.generation == 2, "Generation should increment to 2")

  // New data should not conflict with old
  item2.value = 200
  retrieved, found2 := get(pool, h2)
  testing.expect(t, found2, "Should find new item")
  testing.expect(t, retrieved.value == 200, "Should get new value")

  // Old handle still invalid
  _, still_not_found := get(pool, h1)
  testing.expect(t, !still_not_found, "Old handle still invalid")
}

@(test)
test_pool_multiple_allocs :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool)
  defer destroy(pool, proc(item: ^Test_Item) {})

  handles: [10]Handle
  for i in 0 ..< 10 {
    h, item, ok := alloc(&pool, Handle)
    testing.expect(t, ok, "Allocation should succeed")
    item.value = i * 10
    handles[i] = h
  }

  // Verify all handles work
  for h, i in handles {
    item, found := get(pool, h)
    testing.expect(t, found, "Should find each item")
    testing.expect(t, item.value == i * 10, "Should have correct value")
  }
}

@(test)
test_pool_capacity_limit :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool, capacity = 5)
  defer destroy(pool, proc(item: ^Test_Item) {})

  // Allocate up to capacity
  for i in 0 ..< 5 {
    _, _, ok := alloc(&pool, Handle)
    testing.expect(t, ok, "Allocation within capacity should succeed")
  }

  // Exceed capacity
  _, _, ok := alloc(&pool, Handle)
  testing.expect(t, !ok, "Allocation exceeding capacity should fail")

  // Free one and allocate again
  h, _, _ := alloc(&pool, Handle) // This should fail, but we get h from earlier
  // Actually we need to save a handle from the loop
}

@(test)
test_pool_capacity_limit_with_reuse :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool, capacity = 3)
  defer destroy(pool, proc(item: ^Test_Item) {})

  h1, _, ok1 := alloc(&pool, Handle)
  testing.expect(t, ok1, "First alloc should succeed")

  h2, _, ok2 := alloc(&pool, Handle)
  testing.expect(t, ok2, "Second alloc should succeed")

  h3, _, ok3 := alloc(&pool, Handle)
  testing.expect(t, ok3, "Third alloc should succeed")

  _, _, ok4 := alloc(&pool, Handle)
  testing.expect(t, !ok4, "Fourth alloc should fail (at capacity)")

  // Free one slot
  free(&pool, h2)

  // Should now be able to allocate again
  h5, _, ok5 := alloc(&pool, Handle)
  testing.expect(t, ok5, "Allocation after free should succeed")
  testing.expect(t, h5.index == h2.index, "Should reuse freed slot")
}

@(test)
test_pool_is_valid :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool)
  defer destroy(pool, proc(item: ^Test_Item) {})

  h1, _, _ := alloc(&pool, Handle)
  testing.expect(t, is_valid(pool, h1), "New handle should be valid")

  free(&pool, h1)
  testing.expect(t, !is_valid(pool, h1), "Freed handle should be invalid")

  h2, _, _ := alloc(&pool, Handle)
  testing.expect(t, is_valid(pool, h2), "Reused slot handle should be valid")
  testing.expect(t, !is_valid(pool, h1), "Old handle still invalid")
}

@(test)
test_pool_count :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool)
  defer destroy(pool, proc(item: ^Test_Item) {})

  testing.expect(t, count(pool) == 0, "Count should be 0 initially")

  h1, _, _ := alloc(&pool, Handle)
  testing.expect(t, count(pool) == 1, "Count should be 1 after alloc")

  h2, _, _ := alloc(&pool, Handle)
  testing.expect(t, count(pool) == 2, "Count should be 2")

  free(&pool, h1)
  testing.expect(t, count(pool) == 1, "Count should be 1 after free")

  free(&pool, h2)
  testing.expect(t, count(pool) == 0, "Count should be 0 after freeing all")
}

@(test)
test_pool_generation_wraparound :: proc(t: ^testing.T) {
  pool: Pool(Test_Item)
  init(&pool)
  defer destroy(pool, proc(item: ^Test_Item) {})
  h, _, _ := alloc(&pool, Handle)
  // Manually set generation to max - 1 to test wraparound
  pool.entries[h.index].generation = 0xFFFFFFFF
  free(&pool, Handle{h.index, 0xFFFFFFFF})
  // Next allocation should wrap generation to 1 (skip 0)
  h2, _, _ := alloc(&pool, Handle)
  testing.expect(t, h2.generation == 1, "Generation should wrap to 1 (skip 0)")
}

// Slab Allocator Tests

@(test)
test_slab_init :: proc(t: ^testing.T) {
  allocator: SlabAllocator
  config := [MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  } {
    {block_size = 1, block_count = 10},
    {block_size = 4, block_count = 10},
    {block_size = 16, block_count = 10},
    {block_size = 64, block_count = 10},
    {},
    {},
    {},
    {},
  }
  slab_init(&allocator, config)
  defer slab_destroy(&allocator)

  expected_capacity := u32(1 * 10 + 4 * 10 + 16 * 10 + 64 * 10)
  testing.expect(
    t,
    allocator.capacity == expected_capacity,
    "Capacity should be sum of all class capacities",
  )
}

@(test)
test_slab_alloc_exact_fit :: proc(t: ^testing.T) {
  allocator: SlabAllocator
  config := [MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  } {
    {block_size = 4, block_count = 5},
    {block_size = 8, block_count = 5},
    {},
    {},
    {},
    {},
    {},
    {},
  }
  slab_init(&allocator, config)
  defer slab_destroy(&allocator)

  // Allocate 4 items - should use class 0
  idx1, ok1 := slab_alloc(&allocator, 4)
  testing.expect(t, ok1, "Allocation of 4 should succeed")
  testing.expect(t, idx1 == 0, "First allocation should start at base 0")

  // Allocate 8 items - should use class 1
  idx2, ok2 := slab_alloc(&allocator, 8)
  testing.expect(t, ok2, "Allocation of 8 should succeed")
  testing.expect(t, idx2 == 4 * 5, "Should start at base of class 1") // base = 20
}

@(test)
test_slab_alloc_best_fit :: proc(t: ^testing.T) {
  allocator: SlabAllocator
  config := [MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  } {
    {block_size = 8, block_count = 5},
    {block_size = 16, block_count = 5},
    {},
    {},
    {},
    {},
    {},
    {},
  }
  slab_init(&allocator, config)
  defer slab_destroy(&allocator)

  // Request 3 items - should use class 0 (8 >= 3)
  idx, ok := slab_alloc(&allocator, 3)
  testing.expect(t, ok, "Allocation should succeed")
  testing.expect(t, idx == 0, "Should use first available class")
}

@(test)
test_slab_alloc_and_free :: proc(t: ^testing.T) {
  allocator: SlabAllocator
  config := [MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  }{{block_size = 4, block_count = 3}, {}, {}, {}, {}, {}, {}, {}}
  slab_init(&allocator, config)
  defer slab_destroy(&allocator)

  idx0, _ := slab_alloc(&allocator, 0)
  idx1, _ := slab_alloc(&allocator, 4)
  idx2, _ := slab_alloc(&allocator, 4)

  testing.expect(t, idx1 == 0, "First index should be 0")
  testing.expect(t, idx2 == 4, "Second index should be 4")

  // Free first allocation
  slab_free(&allocator, idx1)
  // Free 0-sized allocation should be a no-op
  slab_free(&allocator, idx0)

  // Allocate again - should reuse idx1
  idx3, ok := slab_alloc(&allocator, 4)
  testing.expect(t, ok, "Reallocation should succeed")
  testing.expect(t, idx3 == 0, "Should reuse freed index 0")
}

@(test)
test_slab_alloc_out_of_space :: proc(t: ^testing.T) {
  allocator: SlabAllocator
  config := [MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  } {
    {block_size = 4, block_count = 2}, // Only 2 blocks
    {},
    {},
    {},
    {},
    {},
    {},
    {},
  }
  slab_init(&allocator, config)
  defer slab_destroy(&allocator)

  _, ok1 := slab_alloc(&allocator, 4)
  testing.expect(t, ok1, "First allocation should succeed")

  _, ok2 := slab_alloc(&allocator, 4)
  testing.expect(t, ok2, "Second allocation should succeed")

  _, ok3 := slab_alloc(&allocator, 4)
  testing.expect(t, !ok3, "Third allocation should fail (out of space)")
}

@(test)
test_slab_alloc_too_large :: proc(t: ^testing.T) {
  allocator: SlabAllocator
  config := [MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  } {
    {block_size = 4, block_count = 10},
    {block_size = 8, block_count = 10},
    {},
    {},
    {},
    {},
    {},
    {},
  }
  slab_init(&allocator, config)
  defer slab_destroy(&allocator)

  // Request 16 items - larger than any class
  _, ok := slab_alloc(&allocator, 16)
  testing.expect(t, !ok, "Allocation larger than any class should fail")
}
