# `mjolnir/containers` — API Reference

Layer 1. Pure data structures with no dependencies on the rest of the engine.

Everything pooled in mjolnir lives in a `Pool` or `PoolSoA`. References are
`Handle` values (generation + index) — never raw pointers. See
[architecture §4](architecture.html#4-handles-not-pointers) for rationale.

## Types

```odin
Handle :: struct {
  index:      u32,
  generation: u32,
}

Entry($T: typeid) :: struct {
  generation: u32,
  active:     bool,
  item:       T,
}

Pool($T: typeid) :: struct {
  entries:      [dynamic]Entry(T),
  free_indices: [dynamic]u32,
  capacity:     u32,   // 0 = unlimited
}

EntrySoA($T: typeid) :: /* struct-of-arrays counterpart of Entry(T) */

PoolSoA($T: typeid) :: struct {
  entries:      #soa[dynamic]EntrySoA(T),
  free_indices: [dynamic]u32,
  capacity:     u32,
}
```

`distinct cont.Handle` is the idiom used everywhere (`NodeHandle`, `MeshHandle`,
`Texture2DHandle`, ...). Distinctness gives compile-time type safety even
though all handles share the same layout.

## Pool procs

| Proc | Signature | Purpose |
|---|---|---|
| `init` | `proc(pool: ^Pool($T), capacity: u32 = 0)` | Initialize. `capacity = 0` = unlimited. |
| `alloc` | `proc(pool: ^Pool($T), $HT: typeid) -> (HT, ^T, bool)` | Allocate slot. Reuses freed first. Returns handle, item, ok. |
| `free` | `proc(pool: ^Pool($T), handle: $HT) -> (^T, bool)` | Mark freed; bumps generation; pushes to free list. |
| `get` | `#force_inline proc(pool: Pool($T), handle: $HT) -> (^T, bool)` | Look up. Returns `nil, false` on stale handle. |
| `is_valid` | `proc(pool: Pool($T), handle: $HT) -> bool` | Validity check without dereference. |
| `count` | `proc(pool: Pool($T)) -> int` | Active item count. |
| `pool_len` | `proc(pool: Pool($T)) -> int` | Total slots (active + freed). |
| `destroy` | `proc(pool: Pool($T), destroy_proc: proc(_: ^T))` | Free memory; runs `destroy_proc` on every active item first. |

## PoolSoA procs

Same surface, suffix `_soa`:

`init_soa`, `alloc_soa`, `free_soa`, `get_soa`, `is_valid_soa`, `count_soa`,
`pool_len_soa`, `destroy_soa`, plus `pool_entry_active_soa` for direct
flag inspection.

`PoolSoA` stores fields as parallel arrays via Odin's `#soa[dynamic]`. Use it
when you iterate one field across all entries (cache-friendly hot loops, e.g.
`physics.bodies` iterates positions only).

## Generation rules

- Slot starts at `generation = 1`. Never 0 (zero-handle = invalid sentinel).
- `free` increments. Wraps `u32::MAX → 1`, skipping 0.
- `get` returns `nil, false` if `entries[index].generation != handle.generation`
  OR `entries[index].active == false`.
- Stale handle access is always defined behavior. No use-after-free.

## SlabAllocator

```odin
MAX_SLAB_CLASSES :: 8

SlabAllocator :: struct {
  classes: [MAX_SLAB_CLASSES]struct {
    block_size:  u32,           // elements per block
    block_count: u32,           // total blocks in this class
    free_list:   [dynamic]u32,  // recycled global indices
    next:        u32,           // next fresh index in this class
    base:        u32,           // global index where this class starts
  },
  capacity: u32,                // total across all classes
}
```

| Proc | Signature | Purpose |
|---|---|---|
| `slab_init` | `proc(a: ^SlabAllocator, config: [MAX_SLAB_CLASSES]struct{block_size, block_count: u32})` | Configure size classes. |
| `slab_destroy` | `proc(a: ^SlabAllocator)` | Free `free_list`s. |
| `slab_alloc` | `proc(a: ^SlabAllocator, count: u32) -> (u32, bool)` | Allocate `count` elements. Returns global index. `count=0` is no-op (returns 0, true). |
| `slab_free` | `proc(a: ^SlabAllocator, index: u32)` | Recycle by index. |

Used by `gpu.MeshManager` to sub-allocate vertices/indices/skinning from giant
GPU buffers. See [architecture §7](architecture.html#7-slab-sub-allocation).
