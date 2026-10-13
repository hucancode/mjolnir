// Index and handle allocation containers used across the engine.
// Pool (handle_pool.odin) stores items behind generational Handles, optionally
// deferring slot reuse by a grace period. Slots (slots.odin) hands out indices into
// caller-owned storage; SlabAllocator (slab_allocator.odin) allocates blocks of
// several size classes from one shared index range.
package containers
