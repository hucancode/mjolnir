package containers

// Slots hands out generational handles to the indices of storage the caller
// owns (a plain array, a GPU table): generations, liveness and a free list,
// no items. With grace > 0 a freed index is reused only `grace` ticks later,
// so a consumer lagging up to `grace` ticks never sees it reused.
Slots :: struct {
  generation: []u32,
  live:       []u64, // bit per index
  free:       [dynamic]u32,
  // Indices freed during tick t wait in bucket t % grace until tick t + grace.
  retiring:   [][dynamic]u32,
  // indices slots_tick reclaimed, valid until the next slots_tick
  reclaimed:  [dynamic]u32,
  tick:       u64,
  // indices ever handed out; every live index is below it
  high_water: u32,
  count:      u32, // live indices
}

slots_init :: proc(s: ^Slots, capacity: u32, grace: u64 = 0) {
  s.generation = make([]u32, capacity)
  // generation 0 marks the null handle
  for &g in s.generation do g = 1
  s.live = make([]u64, (capacity + 63) / 64)
  s.retiring = make([][dynamic]u32, grace)
}

slots_destroy :: proc(s: ^Slots) {
  delete(s.generation)
  delete(s.live)
  delete(s.free)
  for b in s.retiring do delete(b)
  delete(s.retiring)
  delete(s.reclaimed)
  s^ = {}
}

// A live index and its handle; false when every index is taken.
slots_alloc :: proc(s: ^Slots, $H: typeid) -> (handle: H, ok: bool) #optional_ok {
  index: u32
  if len(s.free) > 0 {
    index = pop(&s.free)
  } else if int(s.high_water) < len(s.generation) {
    index = s.high_water
    s.high_water += 1
  } else {
    return
  }
  s.live[index / 64] |= 1 << (index % 64)
  s.count += 1
  return H{index, s.generation[index]}, true
}

// Invalidate `handle` at once; its index is reused after the grace.
slots_free :: proc(s: ^Slots, handle: $H) -> bool {
  if !slots_valid(s, handle) do return false
  index := handle.index
  s.live[index / 64] &~= 1 << (index % 64)
  s.count -= 1
  s.generation[index] += 1
  if s.generation[index] == 0 do s.generation[index] = 1
  if len(s.retiring) == 0 {
    append(&s.free, index)
  } else {
    append(&s.retiring[s.tick % u64(len(s.retiring))], index)
  }
  return true
}

slots_valid :: #force_inline proc "contextless" (s: ^Slots, handle: $H) -> bool {
  return(
    handle.index < u32(len(s.generation)) &&
    s.generation[handle.index] == handle.generation &&
    slots_live(s, handle.index) \
  )
}

slots_live :: #force_inline proc "contextless" (s: ^Slots, index: u32) -> bool {
  return s.live[index / 64] & (1 << (index % 64)) != 0
}

// The handle of live index `index`.
slots_handle :: #force_inline proc "contextless" (s: ^Slots, index: u32, $H: typeid) -> H {
  return H{index, s.generation[index]}
}

// Advance one tick and reuse the indices freed `grace` ticks ago. Returns
// them, so the caller can release what its storage holds there.
slots_tick :: proc(s: ^Slots) -> []u32 {
  clear(&s.reclaimed)
  if len(s.retiring) == 0 do return nil
  s.tick += 1
  bucket := &s.retiring[s.tick % u64(len(s.retiring))]
  append(&s.reclaimed, ..bucket[:])
  append(&s.free, ..bucket[:])
  clear(bucket)
  return s.reclaimed[:]
}

// Reuse every retiring index now, ignoring the grace. Use once no consumer
// can still read them (teardown).
slots_flush :: proc(s: ^Slots) -> []u32 {
  clear(&s.reclaimed)
  for &bucket in s.retiring {
    append(&s.reclaimed, ..bucket[:])
    append(&s.free, ..bucket[:])
    clear(&bucket)
  }
  return s.reclaimed[:]
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

// The item at a valid handle's index of the caller's storage.
slots_get :: #force_inline proc "contextless" (
  s: ^Slots,
  items: []$T,
  handle: $H,
) -> (
  ^T,
  bool,
) #optional_ok {
  if !slots_valid(s, handle) do return nil, false
  return &items[handle.index], true
}
