---
title: Containers
---

Generational handle pool + slab allocator (`slab_init`, `slab_alloc`,
`slab_free`, `slab_destroy`). Layer 1 — depended on by
every other module that owns objects with stable identity.

## Why handles, not pointers

Pointers go stale when a backing array reallocates, and they make
serialization, debugging, and cross-thread ownership painful. Mjolnir
addresses pooled objects through `Handle{index, generation}`. Freed
slots bump their generation, so a stale handle resolves to "not found"
rather than a use-after-free.

A `distinct Handle` per pool type (`NodeHandle`, `MeshHandle`, …) keeps
the safety at compile time without changing the layout.

## Pool

Backing array + a free-list of recycled indices. `init` sizes it,
`alloc` reuses the oldest freed slot before growing, `get` and
`is_valid` resolve handles, and `free` flips `active` and bumps
`generation` (skipping zero on wrap; zero is the invalid-handle
sentinel). `destroy(&pool, cleanup)` runs `cleanup` on live items and
frees the pool.

For consumers that key on slot indices, `free_deferred` holds a slot
back for a grace period. `tick` ages deferred slots once per update
and releases those that expired; `flush` releases all of them.

## SlabAllocator

Range allocator over a single flat buffer, partitioned into a handful of
size classes. Used by render's mesh arena (`render/bindless` `MeshManager`) to sub-allocate vertex / index /
skinning ranges out of a couple of giant GPU buffers — keeps allocation
O(1), avoids per-mesh `vk.Buffer` objects, and gives GPU draw indirect a
stable base offset.
