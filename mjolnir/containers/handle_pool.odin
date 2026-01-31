package containers

import "core:log"

// Handle provides safe, generational access to pooled items.
// The generation prevents use-after-free bugs by invalidating handles when items are freed.
Handle :: struct {
  index:      u32,
  generation: u32,
}

// Entry stores the item along with its generation and active status.
Entry :: struct($T: typeid) {
  generation: u32,
  active:     bool,
  item:       T,
}

// Pool is a handle-based resource pool with generational indices.
// Freed slots are reused, but their generation increments to invalidate old handles.
Pool :: struct($T: typeid) {
  entries:      [dynamic]Entry(T),
  free_indices: [dynamic]u32,
  capacity:     u32, // 0 means unlimited
}

// init initializes a pool with optional capacity limit.
init :: proc(pool: ^Pool($T), capacity: u32 = 0) {
  pool.capacity = capacity
}

// destroy frees the pool's memory, calling deinit_proc on all active items.
destroy :: proc(pool: Pool($T), destroy_proc: proc(_: ^T)) {
  for &entry in pool.entries {
    // Only deinit entries that are still active
    if entry.generation > 0 && entry.active {
      destroy_proc(&entry.item)
    }
  }
  delete(pool.entries)
  delete(pool.free_indices)
}

// alloc allocates a new item from the pool, reusing freed slots when possible.
// Returns (handle, item_ptr, ok). The item is zero-initialized.
alloc :: proc(pool: ^Pool($T), $HT: typeid) -> (handle: HT, item: ^T, ok: bool) {
  MAX_CONSECUTIVE_ERROR :: 20
  @(static) error_count := 0
  // Try to reuse a freed slot
  if len(pool.free_indices) > 0 {
    index := pop(&pool.free_indices)
    entry := &pool.entries[index]
    entry.active = true
    error_count = 0
    return HT{index, entry.generation}, &entry.item, true
  }
  // Allocate a new slot
  index := u32(len(pool.entries))
  if pool.capacity > 0 && index >= pool.capacity {
    error_count += 1
    if error_count < MAX_CONSECUTIVE_ERROR {
      log.warnf(
        "Pool allocation failed: index=%d >= capacity=%d, entries length=%d",
        index,
        pool.capacity,
        len(pool.entries),
      )
    }
    return
  }
  new_item_generation: u32 = 1
  entry_to_add := Entry(T) {
    generation = new_item_generation,
    active     = true,
  }
  append(&pool.entries, entry_to_add)
  error_count = 0
  return HT{index, new_item_generation}, &pool.entries[index].item, true
}

// free marks an item as freed and returns a pointer to it for cleanup.
// The handle becomes invalid immediately. Returns (item_ptr, freed).
free :: proc(pool: ^Pool($T), handle: $HT) -> (item: ^T, freed: bool) {
  if handle.index >= u32(len(pool.entries)) {
    return nil, false
  }
  entry := &pool.entries[handle.index]
  if !entry.active || entry.generation != handle.generation {
    return nil, false
  }
  // Return pointer to item before marking as freed
  item = &entry.item
  // Mark as freed and increment generation
  entry.active = false
  entry.generation += 1
  if entry.generation == 0 {
    entry.generation = 1 // Wrap around, skip 0
  }
  append(&pool.free_indices, handle.index)
  return item, true
}

// get retrieves an item by handle. Returns (item_ptr, found).
get :: #force_inline proc "contextless" (
  pool: Pool($T),
  handle: $HT,
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

// is_valid checks if a handle is currently valid without accessing the item.
is_valid :: proc "contextless" (pool: Pool($T), handle: $HT) -> bool {
  if handle.index >= u32(len(pool.entries)) {
    return false
  }
  entry := &pool.entries[handle.index]
  return entry.active && entry.generation == handle.generation
}

// count returns the number of active items in the pool.
count :: proc "contextless" (pool: Pool($T)) -> int {
  active := 0
  for entry in pool.entries {
    if entry.active do active += 1
  }
  return active
}

// pool_len returns the total capacity (active + freed slots).
pool_len :: proc "contextless" (pool: Pool($T)) -> int {
  return len(pool.entries)
}

EntrySoA :: struct($T: typeid) {
  generation: u32,
  active:     bool,
  item:       T,
}

PoolSoA :: struct($T: typeid) {
  entries:      #soa[dynamic]EntrySoA(T),
  free_indices: [dynamic]u32,
  capacity:     u32, // 0 means unlimited
}

init_soa :: proc(pool: ^PoolSoA($T), capacity: u32 = 0) {
  pool.capacity = capacity
}

destroy_soa :: proc(pool: PoolSoA($T), destroy_proc: proc(_: ^T)) {
  for i in 0..<len(pool.entries) {
    if pool.entries[i].generation > 0 && pool.entries[i].active {
      // With #soa, we need to copy the item to pass a pointer
      // For cleanup, this is acceptable as it's a shutdown operation
      item := pool.entries[i].item
      destroy_proc(&item)
    }
  }
  delete_soa(pool.entries)
  delete(pool.free_indices)
}

alloc_soa :: proc(pool: ^PoolSoA($T), $HT: typeid) -> (handle: HT, item: ^T, ok: bool) {
  MAX_CONSECUTIVE_ERROR :: 20
  @(static) error_count := 0

  // Try to reuse a freed slot
  if len(pool.free_indices) > 0 {
    index := pop(&pool.free_indices)
    // Mark as active
    pool.entries[index].active = true
    entry_generation := pool.entries[index].generation
    error_count = 0
    return HT{index, entry_generation}, &pool.entries[index].item, true
  }

  // Allocate a new slot
  index := u32(len(pool.entries))
  if pool.capacity > 0 && index >= pool.capacity {
    error_count += 1
    if error_count < MAX_CONSECUTIVE_ERROR {
      log.warnf(
        "PoolSoA allocation failed: index=%d >= capacity=%d, entries length=%d",
        index,
        pool.capacity,
        len(pool.entries),
      )
    }
    return
  }

  new_item_generation: u32 = 1
  entry_to_add := EntrySoA(T) {
    generation = new_item_generation,
    active     = true,
  }
  append_soa(&pool.entries, entry_to_add)
  error_count = 0
  return HT{index, new_item_generation}, &pool.entries[index].item, true
}

free_soa :: proc(pool: ^PoolSoA($T), handle: $HT) -> (item: ^T, freed: bool) {
  if handle.index >= u32(len(pool.entries)) {
    return nil, false
  }
  entry_active := pool.entries[handle.index].active
  entry_generation := pool.entries[handle.index].generation
  if !entry_active || entry_generation != handle.generation {
    return nil, false
  }
  item = &pool.entries[handle.index].item
  pool.entries[handle.index].active = false
  new_generation := entry_generation + 1
  if new_generation == 0 {
    new_generation = 1 // Wrap around, skip 0
  }
  pool.entries[handle.index].generation = new_generation
  append(&pool.free_indices, handle.index)
  return item, true
}

// get_soa retrieves an item by handle. Returns (item_ptr, found).
// Note: With #soa, we can't return a true pointer to the item.
// Instead, we return a pointer to a field within the SoA structure.
// This works for reading/writing but the pointer arithmetic is different.
// TODO: this could be a hidden trap if not used correctly, review this later
get_soa :: #force_inline proc(
  pool: ^PoolSoA($T),
  handle: $HT,
) -> (
  ret: ^T,
  found: bool,
) #optional_ok {
  if handle.index >= u32(len(pool.entries)) {
    return nil, false
  }
  entry_active := pool.entries[handle.index].active
  entry_generation := pool.entries[handle.index].generation

  if !entry_active || entry_generation != handle.generation {
    return nil, false
  }
  // For #soa, we return a "pointer" to the item which is actually a view into the SoA
  return &pool.entries[handle.index].item, true
}

is_valid_soa :: proc "contextless" (pool: PoolSoA($T), handle: $HT) -> bool {
  if handle.index >= u32(len(pool.entries)) {
    return false
  }
  entry_active := pool.entries[handle.index].active
  entry_generation := pool.entries[handle.index].generation
  return entry_active && entry_generation == handle.generation
}

count_soa :: proc "contextless" (pool: PoolSoA($T)) -> int {
  active := 0
  for i in 0..<len(pool.entries) {
    if pool.entries[i].active do active += 1
  }
  return active
}

pool_len_soa :: proc "contextless" (pool: PoolSoA($T)) -> int {
  return len(pool.entries)
}

pool_entry_active_soa :: #force_inline proc "contextless" (pool: PoolSoA($T), index: int) -> bool {
  if index >= len(pool.entries) do return false
  return pool.entries[index].active
}
