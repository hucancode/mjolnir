// Index allocation containers used across the engine.
// Slots (slots.odin) hands out indices and generational Handles into caller-owned
// storage, optionally deferring index reuse by a grace period. SlabAllocator
// (slab_allocator.odin) allocates blocks of several size classes from one shared
// index range.
package containers
