package rhi

// Pool is the storage behind a backend's handles: index 0 is none, released slots are reused.
Pool :: struct($T: typeid) {
  items: [dynamic]T,
  free:  [dynamic]u32,
}

// pool_take returns a free slot, its item zeroed.
pool_take :: proc(p: ^Pool($T)) -> u32 {
  if len(p.items) == 0 do append(&p.items, T{})
  if len(p.free) > 0 {
    slot := pop(&p.free)
    p.items[slot] = {}
    return slot
  }
  append(&p.items, T{})
  return u32(len(p.items) - 1)
}

// pool_release zeroes slot and makes it free; 0 is ignored.
pool_release :: proc(p: ^Pool($T), slot: u32) {
  if slot == 0 do return
  p.items[slot] = {}
  append(&p.free, slot)
}

pool_destroy :: proc(p: ^Pool($T)) {
  delete(p.items)
  delete(p.free)
  p^ = {}
}
