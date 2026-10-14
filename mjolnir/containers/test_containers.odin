#+build !js
package containers

import "core:testing"

@(test)
test_slab_alloc_exact_fit :: proc(t: ^testing.T) {
  allocator: SlabAllocator
  config := SlabConfig {
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
  config := SlabConfig {
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
  config := SlabConfig{{block_size = 4, block_count = 3}, {}, {}, {}, {}, {}, {}, {}}
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
  config := SlabConfig {
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
  config := SlabConfig {
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

@(test)
test_slots_alloc_free_reuse :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 4)
  defer slots_destroy(&s)
  i1 := slots_alloc(&s)
  i2 := slots_alloc(&s)
  testing.expect_value(t, i1, 1)
  testing.expect_value(t, i2, 2)
  testing.expect(t, !slots_live(&s, 0), "index 0 is never handed out")
  testing.expect(t, slots_free(&s, i1))
  testing.expect(t, !slots_live(&s, i1), "freed index is not live")
  testing.expect(t, !slots_free(&s, i1), "double free is rejected")
  testing.expect_value(t, slots_alloc(&s), i1)
  testing.expect_value(t, s.count, 2)
  testing.expect_value(t, s.high_water, 3)
}

@(test)
test_slots_capacity :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 3)
  defer slots_destroy(&s)
  slots_alloc(&s)
  slots_alloc(&s)
  _, ok := slots_alloc(&s)
  testing.expect(t, !ok, "allocation past capacity fails")
  testing.expect(t, !slots_live(&s, 1000), "out of range is not live")
}

@(test)
test_slots_grace :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 8, grace = 3)
  defer slots_destroy(&s)
  i := slots_alloc(&s)
  slots_free(&s, i)
  for _ in 0 ..< 2 {
    testing.expect_value(t, len(slots_tick(&s)), 0)
    testing.expect(t, slots_alloc(&s) != i, "index held during grace")
  }
  reclaimed := slots_tick(&s)
  testing.expect_value(t, len(reclaimed), 1)
  testing.expect_value(t, reclaimed[0].index, i)
  testing.expect_value(t, slots_alloc(&s), i)
  testing.expect_value(t, len(slots_tick(&s)), 0)
}

@(test)
test_slots_flush_and_next :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 8, grace = 2)
  defer slots_destroy(&s)
  a := slots_alloc(&s)
  b := slots_alloc(&s)
  c := slots_alloc(&s)
  slots_free(&s, b)
  live: [dynamic]u32
  defer delete(live)
  cursor: u32
  for i in slots_next(&s, &cursor) do append(&live, i)
  testing.expect_value(t, len(live), 2)
  testing.expect_value(t, live[0], a)
  testing.expect_value(t, live[1], c)
  testing.expect_value(t, len(slots_flush(&s)), 1)
  testing.expect_value(t, slots_alloc(&s), b)
}

@(test)
test_slots_generation :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 4)
  defer slots_destroy(&s)
  h := slots_handle(&s, slots_alloc(&s))
  testing.expect(t, slots_valid(&s, h))
  testing.expect(t, !slots_valid(&s, Handle{}), "the zero handle is none")
  slots_free(&s, h.index)
  testing.expect(t, !slots_valid(&s, h), "freed handle is stale")
  reused := slots_handle(&s, slots_alloc(&s))
  testing.expect_value(t, reused.index, h.index)
  testing.expect(t, !slots_valid(&s, h), "stale handle stays stale after reuse")
  testing.expect(t, slots_valid(&s, reused))
}

@(test)
test_slots_rewind :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 8, grace = 2)
  defer slots_destroy(&s)
  kept := slots_alloc(&s)
  slots_mark(&s)
  a := slots_alloc(&s)
  b := slots_alloc(&s)
  ha := slots_handle(&s, a)
  slots_free(&s, b)
  slots_rewind(&s)
  testing.expect(t, slots_live(&s, kept))
  testing.expect(t, !slots_valid(&s, ha))
  testing.expect_value(t, s.count, 1)
  testing.expect_value(t, len(s.retiring), 0)
  // rewound indices come back at once, in order
  testing.expect_value(t, slots_alloc(&s), a)
  testing.expect_value(t, slots_alloc(&s), b)
}

@(test)
test_slots_first :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 8, first = 5)
  defer slots_destroy(&s)
  testing.expect_value(t, slots_alloc(&s), 5)
  slots_rewind(&s)
  testing.expect_value(t, s.count, 0)
  testing.expect_value(t, slots_alloc(&s), 5)
}

@(test)
test_slab_rewind :: proc(t: ^testing.T) {
  slab: SlabAllocator
  slab_init(&slab, {{block_size = 4, block_count = 4}, {block_size = 16, block_count = 2}, {}, {}, {}, {}, {}, {}})
  defer slab_destroy(&slab)
  kept := slab_alloc(&slab, 3)
  big := slab_alloc(&slab, 10)
  slab_mark(&slab)
  a := slab_alloc(&slab, 2)
  slab_alloc(&slab, 12)
  slab_free(&slab, a)
  slab_rewind(&slab)
  testing.expect_value(t, slab_alloc(&slab, 1), kept + 4)
  testing.expect_value(t, slab_alloc(&slab, 16), big + 16)
  // without a mark, rewind frees everything
  plain: SlabAllocator
  slab_init(&plain, {{block_size = 4, block_count = 2}, {}, {}, {}, {}, {}, {}, {}})
  defer slab_destroy(&plain)
  first := slab_alloc(&plain, 4)
  slab_rewind(&plain)
  testing.expect_value(t, slab_alloc(&plain, 4), first)
}
