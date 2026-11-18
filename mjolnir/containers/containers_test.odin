#+build !js
#+private
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
  testing.expect_value(t, slots_count(&s), 2)
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
  testing.expect_value(t, slots_count(&s), 1)
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
  testing.expect_value(t, slots_count(&s), 0)
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

@(test)
test_ranges_alloc_free_merge :: proc(t: ^testing.T) {
  r: Ranges
  ranges_init(&r, 100)
  defer ranges_destroy(&r)
  a := ranges_alloc(&r, 30)
  b := ranges_alloc(&r, 30)
  c := ranges_alloc(&r, 30)
  testing.expect(t, a == 0 && b == 30 && c == 60, "first fit, exactly sized")
  _, full := ranges_alloc(&r, 20)
  testing.expect(t, !full, "only 10 left")
  ranges_free(&r, b)
  ranges_free(&r, a)
  big, ok := ranges_alloc(&r, 60)
  testing.expect(t, ok && big == 0, "neighbouring free runs merge")
  testing.expect_value(t, ranges_size(&r, big), 60)
  ranges_mark(&r)
  ranges_free(&r, c)
  later := ranges_alloc(&r, 5)
  ranges_rewind(&r)
  testing.expect(t, ranges_size(&r, later) == 0 && ranges_size(&r, big) == 60, "rewind frees what came after the mark")
  rest, rest_ok := ranges_alloc(&r, 40)
  testing.expect(t, rest_ok && rest == 60, "and its run merges back")
}

@(test)
test_slots_grow_past_reserve :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 4)
  defer slots_destroy(&s)
  handles: [dynamic]Handle
  defer delete(handles)
  for _ in 0 ..< 10_000 {
    index, ok := slots_alloc(&s)
    if !ok {
      slots_grow(&s, s.capacity * 2)
      index, ok = slots_alloc(&s)
    }
    testing.expect(t, ok)
    append(&handles, slots_handle(&s, index))
  }
  testing.expect(t, s.capacity >= 10_001)
  for h, i in handles {
    testing.expect_value(t, h.index, u32(i + 1))
    testing.expect(t, slots_valid(&s, h), "handles from before every growth stay valid")
  }
  testing.expect_value(t, slots_count(&s), 10_000)
  n := 0
  cursor: u32
  for _ in slots_next(&s, &cursor) do n += 1
  testing.expect_value(t, n, 10_000)
}

@(test)
test_slots_grow_keeps_generations :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 4)
  defer slots_destroy(&s)
  old := slots_handle(&s, slots_alloc(&s))
  slots_free(&s, old.index)
  reused := slots_handle(&s, slots_alloc(&s))
  slots_grow(&s, 1000)
  testing.expect(t, !slots_valid(&s, old), "a stale handle stays stale through growth")
  testing.expect(t, slots_valid(&s, reused))
  slots_grow(&s, 10)
  testing.expect_value(t, s.capacity, 1000)
}

@(test)
test_slots_grace_across_growth :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 4, grace = 3)
  defer slots_destroy(&s)
  i := slots_alloc(&s)
  h := slots_handle(&s, i)
  slots_free(&s, i)
  slots_grow(&s, 64)
  for _ in 0 ..< 2 {
    slots_tick(&s)
    testing.expect(t, slots_alloc(&s) != i, "index held during grace, even after growth")
  }
  slots_tick(&s)
  testing.expect_value(t, slots_alloc(&s), i)
  testing.expect(t, !slots_valid(&s, h))
}

@(test)
test_slots_rewind_after_growth :: proc(t: ^testing.T) {
  s: Slots
  slots_init(&s, 4, grace = 2)
  defer slots_destroy(&s)
  for _ in 0 ..< 3 do slots_alloc(&s)
  slots_mark(&s)
  slots_grow(&s, 1024)
  grown: [dynamic]Handle
  defer delete(grown)
  for _ in 0 ..< 1000 do append(&grown, slots_handle(&s, slots_alloc(&s)))
  slots_free(&s, grown[10].index)
  slots_rewind(&s)
  testing.expect_value(t, s.high_water, 4)
  testing.expect_value(t, slots_count(&s), 3)
  for h in grown do testing.expect(t, !slots_valid(&s, h), "every index past the mark is stale")
  testing.expect_value(t, slots_alloc(&s), 4)
}

@(test)
test_slots_reclaim_ring :: proc(t: ^testing.T) {
  N :: 100_000
  s: Slots
  slots_init(&s, N + 1, grace = 3)
  defer slots_destroy(&s)
  for _ in 0 ..< N do slots_alloc(&s)
  // free 1000 per tick; reuse must come back in free order once each batch matures
  expected: [dynamic]u32
  defer delete(expected)
  got: [dynamic]u32
  defer delete(got)
  next := u32(1)
  for next <= N || len(s.retiring) - s.head - s.reclaimed > 0 {
    for _ in 0 ..< 1000 do if next <= N {
      slots_free(&s, next)
      append(&expected, next)
      next += 1
    }
    for r in slots_tick(&s) do append(&got, r.index)
    testing.expect(t, len(s.retiring) <= 8000, "retiring stays bounded by the grace window")
  }
  testing.expect_value(t, len(got), N)
  for i in 0 ..< min(len(got), len(expected)) do if got[i] != expected[i] {
    testing.expectf(t, false, "reclaim %d: got %d, want %d", i, got[i], expected[i])
    break
  }
}

@(test)
test_ranges_grow :: proc(t: ^testing.T) {
  r: Ranges
  ranges_init(&r, 100)
  defer ranges_destroy(&r)
  a := ranges_alloc(&r, 60)
  b := ranges_alloc(&r, 30)
  _, ok := ranges_alloc(&r, 50)
  testing.expect(t, !ok, "only 10 left")
  ranges_grow(&r, 200)
  c, grown := ranges_alloc(&r, 50)
  testing.expect(t, grown && c == 90, "the trailing free run merges with the new room")
  testing.expect(t, ranges_size(&r, a) == 60 && ranges_size(&r, b) == 30, "live runs keep their place")
  testing.expect_value(t, len(r.free), 1)
  testing.expect_value(t, r.free[0], [2]u32{140, 60})
  // growth with no trailing free run
  full: Ranges
  ranges_init(&full, 10)
  defer ranges_destroy(&full)
  ranges_alloc(&full, 10)
  ranges_grow(&full, 20)
  d, d_ok := ranges_alloc(&full, 10)
  testing.expect(t, d_ok && d == 10)
}

@(test)
test_ranges_rewind_after_growth :: proc(t: ^testing.T) {
  r: Ranges
  ranges_init(&r, 16)
  defer ranges_destroy(&r)
  kept := ranges_alloc(&r, 8)
  ranges_mark(&r)
  ranges_grow(&r, 64)
  later := ranges_alloc(&r, 40)
  ranges_rewind(&r)
  testing.expect(t, ranges_size(&r, kept) == 8 && ranges_size(&r, later) == 0)
  testing.expect_value(t, len(r.free), 1)
  testing.expect_value(t, r.free[0], [2]u32{8, 56})
}
