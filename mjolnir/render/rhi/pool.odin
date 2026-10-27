package rhi

// Pool is the storage behind a backend's handles: index 0 is none, released slots are reused.
Pool :: struct($T: typeid) {
  items: [dynamic]T,
  free:  [dynamic]u32,
}

// pool_take stores item in a free slot and returns the slot.
pool_take :: proc(p: ^Pool($T), item: T) -> u32 {
  if len(p.items) == 0 do append(&p.items, T{})
  if len(p.free) > 0 {
    slot := pop(&p.free)
    p.items[slot] = item
    return slot
  }
  append(&p.items, item)
  return u32(len(p.items) - 1)
}

// pool_release zeroes slot and makes it free; 0 is ignored.
pool_release :: proc(p: ^Pool($T), slot: u32) {
  if slot == 0 do return
  p.items[slot] = {}
  append(&p.free, slot)
}

// pool_destroy frees the pool's storage; what its items hold is the caller's to release first.
pool_destroy :: proc(p: ^Pool($T)) {
  delete(p.items)
  delete(p.free)
  p^ = {}
}
