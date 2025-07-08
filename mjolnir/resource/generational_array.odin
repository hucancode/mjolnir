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

Pool :: struct($T: typeid) {
  entries:      [dynamic]Entry(T),
  free_indices: [dynamic]u32,
}

pool_init :: proc(pool: ^Pool($T)) {
  pool.entries = make([dynamic]Entry(T), 0, 0)
  pool.free_indices = make([dynamic]u32, 0, 0)
}

pool_deinit :: proc(pool: Pool($T), deinit_proc: proc(_: ^T)) {
  for &entry in pool.entries {
    // Only deinit entries that are still active (not freed with callback)
    // Resources freed with callback have already been cleaned up
    if entry.generation > 0 && entry.active {
      deinit_proc(&entry.item)
    }
  }
  delete(pool.entries)
  delete(pool.free_indices)
}

alloc :: proc(pool: ^Pool($T)) -> (Handle, ^T) {
  index, has_free_index := pop_safe(&pool.free_indices)
  if has_free_index {
    entry := &pool.entries[index]
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

free :: proc {
  free_without_callback,
  free_with_callback,
}

free_without_callback :: proc(pool: ^Pool($T), handle: Handle) {
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

free_with_callback :: proc(pool: ^Pool($T), handle: Handle, deinit_proc: proc(_: ^T)) {
  if handle.index >= u32(len(pool.entries)) {
    return
  }
  entry := &pool.entries[handle.index]
  if !entry.active || entry.generation != handle.generation {
    return
  }
  // Call the deinit procedure immediately before marking as freed
  deinit_proc(&entry.item)
  entry.active = false
  entry.generation += 1
  if entry.generation == 0 {
    entry.generation = 1
  }
  append(&pool.free_indices, handle.index)
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
