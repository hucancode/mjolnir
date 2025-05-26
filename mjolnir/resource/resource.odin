package resource

Handle :: struct {
  index:      u32,
  generation: u32,
}

Entry :: struct($T: typeid) {
  generation: u32,
  active:     bool,
  item:       T,
}

ResourcePool :: struct($T: typeid) {
  entries:      [dynamic]Entry(T),
  free_indices: [dynamic]u32,
}

pool_init :: proc(pool: ^ResourcePool($T)) {
  pool.entries = make([dynamic]Entry(T), 0, 0)
  pool.free_indices = make([dynamic]u32, 0, 0)
}

pool_deinit :: proc(pool: ^ResourcePool($T)) {
  delete(pool.entries)
  delete(pool.free_indices)
}

alloc :: proc(pool: ^ResourcePool($T)) -> (Handle, ^T) {
  if len(pool.free_indices) > 0 {
    index := pop(&pool.free_indices)
    entry := &pool.entries[index]
    entry.generation += 1
    if entry.generation == 0 {
      entry.generation = 1
    }
    entry.active = true
    return Handle{index, entry.generation}, &entry.item
  } else {
    index := u32(len(pool.entries))
    new_item_generation: u32 = 1
    entry_to_add := Entry(T) {
      generation = new_item_generation,
      active     = true,
    }
    append(&pool.entries, entry_to_add)
    return Handle{index, new_item_generation}, &pool.entries[index].item
  }
}

free :: proc(pool: ^ResourcePool($T), handle: Handle) {
  if handle.index >= u32(len(pool.entries)) {
    return
  }
  entry := &pool.entries[handle.index]
  if !entry.active || entry.generation != handle.generation {
    return
  }
  entry.active = false
  entry.generation += 1
  if entry.generation == 0 {
    entry.generation = 1
  }
  append(&pool.free_indices, handle.index)
}

get :: proc(pool: ^ResourcePool($T), handle: Handle) -> ^T {
  if handle.index >= u32(len(pool.entries)) {
    // log.debugf("ResourcePool.get: index (%v) out of bounds (%v)", handle.index, len(pool.entries))
    return nil
  }
  entry := &pool.entries[handle.index]
  if !entry.active {
    // log.debugf("ResourcePool.get: index (%v) has been freed", handle.index) // Optional debug
    return nil
  }
  if entry.generation != handle.generation {
    // log.debugf("ResourcePool.get: index (%v) generation mismatch, handle: %v vs entry: %v", handle.index, handle.generation, entry.generation) // Optional debug
    return nil
  }
  return &entry.item
}
