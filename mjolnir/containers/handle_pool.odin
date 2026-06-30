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

// Retiring records a slot that has been logically freed but whose index must
// not be recycled yet — `ready` is the pool frame at which it becomes safe.
Retiring :: struct {
  index: u32,
  ready: u64,
}

// Pool is a handle-based resource pool with generational indices.
// Freed slots are reused, but their generation increments to invalidate old handles.
//
// When `grace > 0` the pool is frame-aware: free_deferred() invalidates the
// handle immediately but holds the slot for `grace` ticks before it can be
// recycled, so the GPU (which lags by FRAMES_IN_FLIGHT) never reads or has its
// resource torn down while a despawned slot is reused by a new entry.
Pool :: struct($T: typeid) {
  entries:      [dynamic]Entry(T),
  free_indices: [dynamic]u32,
  capacity:     u32, // 0 means unlimited
  retiring:     [dynamic]Retiring, // slots freed via free_deferred, awaiting grace
  frame:        u64, // monotonic tick counter, advanced by pool_tick
  grace:        u64, // ticks a freed slot waits before recycle (0 = immediate free)
}

// init initializes a pool with optional capacity limit and retirement grace.
init :: proc(pool: ^Pool($T), capacity: u32 = 0, grace: u64 = 0) {
  pool.grace = grace
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
  delete(pool.retiring)
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

// free_deferred invalidates the handle immediately (gen++, inactive — so get()
// returns nil at once) but holds the slot index for `grace` ticks before it can
// be recycled. The item is left intact so pool_tick can run a destroy callback
// on it at maturity. Use for pools whose GPU resources lag behind the CPU.
free_deferred :: proc(pool: ^Pool($T), handle: $HT) -> bool {
  if handle.index >= u32(len(pool.entries)) {
    return false
  }
  entry := &pool.entries[handle.index]
  if !entry.active || entry.generation != handle.generation {
    return false
  }
  entry.active = false
  entry.generation += 1
  if entry.generation == 0 {
    entry.generation = 1 // Wrap around, skip 0
  }
  append(&pool.retiring, Retiring{handle.index, pool.frame + pool.grace})
  return true
}

// pool_tick advances the pool's frame and reclaims every slot whose grace has
// elapsed: destroy_proc (if any) runs on the still-intact item, the slot is
// zeroed, then made available to alloc. Call once per frame for deferred pools.
pool_tick :: proc(
  pool: ^Pool($T),
  user: rawptr,
  destroy_proc: proc(item: ^T, user: rawptr),
) {
  pool.frame += 1
  i := 0
  for i < len(pool.retiring) {
    r := pool.retiring[i]
    if r.ready > pool.frame {
      i += 1
      continue
    }
    entry := &pool.entries[r.index]
    if destroy_proc != nil {
      destroy_proc(&entry.item, user)
    }
    entry.item = {}
    append(&pool.free_indices, r.index)
    unordered_remove(&pool.retiring, i)
  }
}

// pool_flush matures every retiring slot now, ignoring grace. Use at teardown,
// where there are no more in-flight GPU frames to wait for.
pool_flush :: proc(
  pool: ^Pool($T),
  user: rawptr,
  destroy_proc: proc(item: ^T, user: rawptr),
) {
  for r in pool.retiring {
    entry := &pool.entries[r.index]
    if destroy_proc != nil {
      destroy_proc(&entry.item, user)
    }
    entry.item = {}
    append(&pool.free_indices, r.index)
  }
  clear(&pool.retiring)
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
