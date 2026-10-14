package containers

// Handle is an index with the generation it was handed out at; it goes stale when the index is freed.
// The zero Handle is none.
Handle :: struct {
  index:      u32,
  generation: u32,
}

// Retiring is an index freed but not yet reusable: `ready` is the tick it may be reused at.
Retiring :: struct {
  index: u32,
  ready: u64,
}

// Slots hands out indices of storage the caller owns (a plain array, a GPU
// table): liveness, generations and a free list, no items. Index 0 is never
// handed out, so a zero index means none. With grace > 0 a freed index is
// reused only `grace` ticks later, so a consumer lagging up to `grace` ticks
// never sees it reused.
Slots :: struct {
  live:       []u64, // bit per index
  // per index, bumped when it is freed; stale handles carry an older one
  generation: []u32,
  free:       [dynamic]u32,
  // Freed indices in free order with the tick they mature at; ticks only
  // grow, so the matured ones are a prefix. The first `reclaimed` entries
  // are the ones slots_tick / slots_flush last returned.
  retiring:   [dynamic]Retiring,
  reclaimed:  int,
  grace:      u64,
  tick:       u64,
  // indices ever handed out, plus the reserved ones below `first`; every live index is below it
  high_water: u32,
  // slots_rewind frees every index from here on; slots_mark moves it to high_water
  mark:       u32,
  count:      u32, // live indices
  capacity:   u32,
}

// slots_init sets up s for indices first ..< capacity (index 0 is always reserved) with an
// optional reuse grace in ticks. Pools splitting one array take disjoint ranges.
slots_init :: proc(s: ^Slots, capacity: u32, grace: u64 = 0, first: u32 = 1) {
  s.live = make([]u64, (capacity + 63) / 64)
  s.generation = make([]u32, capacity)
  s.grace = grace
  s.capacity = capacity
  s.high_water = max(first, 1)
  s.mark = s.high_water
}

// slots_destroy frees the memory held by s and zeroes it.
slots_destroy :: proc(s: ^Slots) {
  delete(s.live)
  delete(s.generation)
  delete(s.free)
  delete(s.retiring)
  s^ = {}
}

// slots_alloc returns a live index; false when every index is taken.
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

// slots_free releases `index` at once; it is reused after the grace.
slots_free :: proc(s: ^Slots, index: u32) -> bool {
  if !slots_live(s, index) do return false
  s.live[index / 64] &~= 1 << (index % 64)
  s.generation[index] += 1
  s.count -= 1
  if s.grace == 0 do append(&s.free, index)
  else do append(&s.retiring, Retiring{index, s.tick + s.grace})
  return true
}

// slots_live reports whether index is currently allocated.
slots_live :: #force_inline proc "contextless" (s: ^Slots, index: u32) -> bool {
  return index < s.capacity && s.live[index / 64] & (1 << (index % 64)) != 0
}

// slots_handle returns the handle of a live index.
slots_handle :: #force_inline proc "contextless" (s: ^Slots, index: u32) -> Handle {
  return {index, s.generation[index]}
}

// slots_valid reports whether handle h (a Handle or a distinct Handle) is live and not stale.
slots_valid :: #force_inline proc "contextless" (s: ^Slots, h: $HT) -> bool {
  return slots_live(s, h.index) && s.generation[h.index] == h.generation
}

// slots_tick advances one tick and reuses the indices freed `grace` ticks ago. Returns
// them, valid until the next slots_tick or slots_flush, so the caller can
// release what its storage holds there.
slots_tick :: proc(s: ^Slots) -> []Retiring {
  s.tick += 1
  return reclaim(s, s.tick)
}

// slots_flush reuses every retiring index now, ignoring the grace. Use once no consumer
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

// slots_mark keeps every index handed out so far through slots_rewind.
slots_mark :: proc(s: ^Slots) {
  s.mark = s.high_water
}

// slots_rewind frees every index from the mark on at once, live or retiring, ignoring the
// grace. Use once no consumer can still read them; the caller drops what its storage holds
// in mark ..< the old high_water.
slots_rewind :: proc(s: ^Slots) {
  for i in s.mark ..< s.high_water {
    if !slots_live(s, i) do continue
    s.live[i / 64] &~= 1 << (i % 64)
    s.generation[i] += 1
    s.count -= 1
  }
  remove_range(&s.retiring, 0, s.reclaimed)
  s.reclaimed = 0
  n := 0
  for r in s.retiring do if r.index < s.mark {s.retiring[n] = r; n += 1}
  resize(&s.retiring, n)
  n = 0
  for i in s.free do if i < s.mark {s.free[n] = i; n += 1}
  resize(&s.free, n)
  s.high_water = s.mark
}

// slots_next walks the live indices in order:
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
