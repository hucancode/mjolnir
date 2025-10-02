package resources

Handle :: struct {
  index:      u32,
  generation: u32,
}

Entry :: struct($T: typeid) {
  generation: u32,
  active:     bool,
  item:       T,
}

Pool :: struct($T: typeid) {
  entries:      [dynamic]Entry(T),
  free_indices: [dynamic]u32,
  capacity:     u32,
}

pool_init :: proc(self: ^Pool($T), capacity: u32 = 0) {
  self.entries = make([dynamic]Entry(T), 0, 0)
  self.free_indices = make([dynamic]u32, 0, 0)
  self.capacity = capacity
}

pool_destroy :: proc(pool: Pool($T), deinit_proc: proc(_: ^T)) {
  for &entry in pool.entries {
    // Only deinit entries that are still active
    if entry.generation > 0 && entry.active {
      deinit_proc(&entry.item)
    }
  }
  delete(pool.entries)
  delete(pool.free_indices)
}

alloc :: proc(pool: ^Pool($T)) -> (handle: Handle, item: ^T, ok: bool) {
  index, has_free_index := pop_safe(&pool.free_indices)
  if has_free_index {
    entry := &pool.entries[index]
    entry.active = true
    return Handle{index, entry.generation}, &entry.item, true
  } else {
    index := u32(len(pool.entries))
    if pool.capacity > 0 && index >= pool.capacity {
      return Handle{}, nil, false
    }
    new_item_generation: u32 = 1
    entry_to_add := Entry(T) {
      generation = new_item_generation,
      active     = true,
    }
    append(&pool.entries, entry_to_add)
    return Handle{index, new_item_generation}, &pool.entries[index].item, true
  }
}

// New free function that returns (item, freed) for caller-managed deinitialization
free :: proc(pool: ^Pool($T), handle: Handle) -> (item: ^T, freed: bool) {
  if handle.index >= u32(len(pool.entries)) {
    return nil, false
  }
  entry := &pool.entries[handle.index]
  if !entry.active || entry.generation != handle.generation {
    return nil, false
  }
  // Return pointer to item before marking as freed
  item = &entry.item
  // Mark as freed
  entry.active = false
  entry.generation += 1
  if entry.generation == 0 {
    entry.generation = 1
  }
  append(&pool.free_indices, handle.index)
  return item, true
}

get :: proc(
  pool: Pool($T),
  handle: Handle,
) -> (
  ret: ^T,
  found: bool,
) #optional_ok {
  if handle.index >= u32(len(pool.entries)) {
    return nil, false
  }
  entry := &pool.entries[handle.index]
  if !entry.active || entry.generation != handle.generation {
    return nil, false
  }
  return &entry.item, true
}
