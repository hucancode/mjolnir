package containers

// Slots hands out indices of storage the caller owns (a plain array, a GPU
// table): liveness and a free list, no items. Index 0 is never handed out, so
// a zero index means none. With grace > 0 a freed index is reused only
// `grace` ticks later, so a consumer lagging up to `grace` ticks never sees it
// reused.
Slots :: struct {
  live:       []u64, // bit per index
  free:       [dynamic]u32,
  // Freed indices in free order with the tick they mature at; ticks only
  // grow, so the matured ones are a prefix. The first `reclaimed` entries
  // are the ones slots_tick / slots_flush last returned.
  retiring:   [dynamic]Retiring,
  reclaimed:  int,
  grace:      u64,
  tick:       u64,
  // indices ever handed out, plus the reserved 0; every live index is below it
  high_water: u32,
  count:      u32, // live indices
  capacity:   u32,
}

slots_init :: proc(s: ^Slots, capacity: u32, grace: u64 = 0) {
  s.live = make([]u64, (capacity + 63) / 64)
  s.grace = grace
  s.capacity = capacity
  s.high_water = 1
}

slots_destroy :: proc(s: ^Slots) {
  delete(s.live)
  delete(s.free)
  delete(s.retiring)
  s^ = {}
}

// A live index; false when every index is taken.
slots_alloc :: proc(s: ^Slots) -> (index: u32, ok: bool) #optional_ok {
  if len(s.free) > 0 {
    index = pop(&s.free)
  } else if s.high_water < s.capacity {
    index = s.high_water
    s.high_water += 1
  } else {
    return
  }
  s.live[index / 64] |= 1 << (index % 64)
  s.count += 1
  return index, true
}

// Release `index` at once; it is reused after the grace.
slots_free :: proc(s: ^Slots, index: u32) -> bool {
  if !slots_live(s, index) do return false
  s.live[index / 64] &~= 1 << (index % 64)
  s.count -= 1
  if s.grace == 0 do append(&s.free, index)
  else do append(&s.retiring, Retiring{index, s.tick + s.grace})
  return true
}

slots_live :: #force_inline proc "contextless" (s: ^Slots, index: u32) -> bool {
  return index < s.capacity && s.live[index / 64] & (1 << (index % 64)) != 0
}

// Advance one tick and reuse the indices freed `grace` ticks ago. Returns
// them, valid until the next slots_tick or slots_flush, so the caller can
// release what its storage holds there.
slots_tick :: proc(s: ^Slots) -> []Retiring {
  s.tick += 1
  return reclaim(s, s.tick)
}

// Reuse every retiring index now, ignoring the grace. Use once no consumer
// can still read them (teardown).
slots_flush :: proc(s: ^Slots) -> []Retiring {
  return reclaim(s, max(u64))
}

@(private = "file")
reclaim :: proc(s: ^Slots, tick: u64) -> []Retiring {
  remove_range(&s.retiring, 0, s.reclaimed)
  s.reclaimed = 0
  for r in s.retiring {
    if r.ready > tick do break
    append(&s.free, r.index)
    s.reclaimed += 1
  }
  return s.retiring[:s.reclaimed]
}

// Walk the live indices in order:
//   cursor: u32
//   for index in slots_next(&slots, &cursor) { ... }
slots_next :: proc "contextless" (s: ^Slots, cursor: ^u32) -> (index: u32, ok: bool) {
  for cursor^ < s.high_water {
    index = cursor^
    cursor^ += 1
    if slots_live(s, index) do return index, true
  }
  return 0, false
}
