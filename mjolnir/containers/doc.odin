// Index and handle allocation for arrays you own (Slots), a multi-size block allocator
// (SlabAllocator) and a first-fit range allocator (Ranges): slots_alloc an index into your own
// array, slots_handle to hand it out, slots_free it.
package containers

// Layer 0: core
