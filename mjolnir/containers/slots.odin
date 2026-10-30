package containers

import "base:intrinsics"

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
  capacity: u32,
  using _:  Slots_State,
}

@(private)
Slots_State :: struct {
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
}

// slots_init sets up self for indices first ..< capacity (index 0 is always reserved) with an
// optional reuse grace in ticks. Pools splitting one array take disjoint ranges.
slots_init :: proc(self: ^Slots, capacity: u32, grace: u64 = 0, first: u32 = 1) {
  self.live = make([]u64, (capacity + 63) / 64)
  self.generation = make([]u32, capacity)
  self.grace = grace
  self.capacity = capacity
  self.high_water = max(first, 1)
  self.mark = self.high_water
}

// slots_destroy frees the memory held by self and zeroes it.
slots_destroy :: proc(self: ^Slots) {
  delete(self.live)
  delete(self.generation)
  delete(self.free)
  delete(self.retiring)
  self^ = {}
}

// slots_alloc returns a live index; false when every index is taken.
slots_alloc :: proc(self: ^Slots) -> (index: u32, ok: bool) #optional_ok {
  if len(self.free) > 0 {
    index = pop(&self.free)
  } else if self.high_water < self.capacity {
    index = self.high_water
    self.high_water += 1
  } else {
    return
  }
  self.live[index / 64] |= 1 << (index % 64)
  return index, true
}

// slots_free releases `index` at once; it is reused after the grace.
slots_free :: proc(self: ^Slots, index: u32) -> bool {
  if !slots_live(self, index) do return false
  self.live[index / 64] &~= 1 << (index % 64)
  self.generation[index] += 1
  if self.grace == 0 do append(&self.free, index)
  else do append(&self.retiring, Retiring{index, self.tick + self.grace})
  return true
}

// slots_live reports whether index is currently allocated.
slots_live :: #force_inline proc "contextless" (self: ^Slots, index: u32) -> bool {
  return index < self.capacity && self.live[index / 64] & (1 << (index % 64)) != 0
}

// slots_count returns how many indices are live.
slots_count :: proc "contextless" (self: ^Slots) -> (n: u32) {
  for word in self.live[:(self.high_water + 63) / 64] do n += u32(intrinsics.count_ones(word))
  return
}

// slots_handle returns the handle of a live index.
slots_handle :: #force_inline proc "contextless" (self: ^Slots, index: u32) -> Handle {
  return {index, self.generation[index]}
}

// slots_valid reports whether handle h (a Handle or a distinct Handle) is live and not stale.
slots_valid :: #force_inline proc "contextless" (self: ^Slots, h: $HT) -> bool {
  return slots_live(self, h.index) && self.generation[h.index] == h.generation
}

// slots_tick advances one tick and reuses the indices freed `grace` ticks ago. Returns
// them, valid until the next slots_tick or slots_flush, so the caller can
// release what its storage holds there.
slots_tick :: proc(self: ^Slots) -> []Retiring {
  self.tick += 1
  return reclaim(self, self.tick)
}

// slots_flush reuses every retiring index now, ignoring the grace. Use once no consumer
// can still read them (teardown).
slots_flush :: proc(self: ^Slots) -> []Retiring {
  return reclaim(self, max(u64))
}

@(private = "file")
reclaim :: proc(self: ^Slots, tick: u64) -> []Retiring {
  remove_range(&self.retiring, 0, self.reclaimed)
  self.reclaimed = 0
  for r in self.retiring {
    if r.ready > tick do break
    append(&self.free, r.index)
    self.reclaimed += 1
  }
  return self.retiring[:self.reclaimed]
}

// slots_mark keeps every index handed out so far through slots_rewind.
slots_mark :: proc(self: ^Slots) {
  self.mark = self.high_water
}

// slots_rewind frees every index from the mark on at once, live or retiring, ignoring the
// grace. Use once no consumer can still read them; the caller drops what its storage holds
// in mark ..< the old high_water.
slots_rewind :: proc(self: ^Slots) {
  for i in self.mark ..< self.high_water {
    if !slots_live(self, i) do continue
    self.live[i / 64] &~= 1 << (i % 64)
    self.generation[i] += 1
  }
  remove_range(&self.retiring, 0, self.reclaimed)
  self.reclaimed = 0
  n := 0
  for r in self.retiring do if r.index < self.mark {self.retiring[n] = r; n += 1}
  resize(&self.retiring, n)
  n = 0
  for i in self.free do if i < self.mark {self.free[n] = i; n += 1}
  resize(&self.free, n)
  self.high_water = self.mark
}

// slots_next walks the live indices in order:
//   cursor: u32
//   for index in slots_next(&slots, &cursor) { ... }
slots_next :: proc "contextless" (self: ^Slots, cursor: ^u32) -> (index: u32, ok: bool) {
  for cursor^ < self.high_water {
    index = cursor^
    cursor^ += 1
    if slots_live(self, index) do return index, true
  }
  return 0, false
}

// destroy frees a Slots or SlabAllocator, as its *_destroy does.
destroy :: proc {
  slots_destroy,
  slab_destroy,
}
