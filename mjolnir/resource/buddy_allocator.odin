package resource

import "core:slice"
import "core:math/bits"

Range :: struct {
  start: u32,
  count: u32,
}

MAX_BUDDY_ORDERS :: 16 // Supports up to 2^16 = 65536 slots

BuddyAllocator :: struct {
    capacity: u32, // must be power of two
    min_order: u32, // smallest block size = 2^min_order
    max_order: u32, // largest block size = 2^max_order
    free_lists: [MAX_BUDDY_ORDERS][dynamic]u32, // free block start indices for each order
}

make_buddy_allocator :: proc(capacity: u32, min_order: u32) -> BuddyAllocator {
    assert((capacity & (capacity-1)) == 0) // must be power of two
    max_order := bits.len(capacity) - 1
    ba := BuddyAllocator{
        capacity = capacity,
        min_order = min_order,
        max_order = u32(max_order),
    }
    // Initially, all memory is one big free block
    append(&ba.free_lists[ba.max_order], 0)
    return ba
}

buddy_alloc :: proc(ba: ^BuddyAllocator, count: u32) -> (index: u32, ok: bool) #optional_ok {
    // Find smallest order >= count
    order := ba.min_order
    for (1 << order) < count do order += 1
    if order > ba.max_order {
      return 0, false
    }
    // Find a free block at order or above
    o := order
    for o <= ba.max_order && len(ba.free_lists[o]) == 0 do o += 1
    if o > ba.max_order {
      // no space
      return 0, false
    }
    // Split blocks down to requested order
    idx, found := pop_safe(&ba.free_lists[o])
    if !found {
      // no space
      return 0, false
    }
    for o > order {
        o -= 1
        buddy := idx + (1 << o)
        append(&ba.free_lists[o], buddy)
    }
    return idx, true
}

buddy_free :: proc(ba: ^BuddyAllocator, index: u32, count: u32) {
    // Find order
    order := ba.min_order
    for (1 << order) < count do order += 1
    assert((1 << order) == count)
    curr_idx := index
    curr_order := order
    for curr_order < ba.max_order {
        buddy := curr_idx ~ (1 << curr_order)
        // Search for buddy in free list
        found := false
        for b, i in ba.free_lists[curr_order] {
            if b == buddy {
                // Remove buddy and merge
                unordered_remove(&ba.free_lists[curr_order], i)
                curr_idx = min(curr_idx, buddy)
                curr_order += 1
                found = true
                break
            }
        }
        if !found {
          break
        }
    }
    append(&ba.free_lists[curr_order], curr_idx)
}
