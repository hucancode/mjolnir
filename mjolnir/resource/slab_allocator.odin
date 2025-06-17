package resource
// Generic Slab Allocator for fixed-size objects

SlabAllocator :: struct {
    capacity: u32,
    free_list: [dynamic]u32, // stack of free indices
    next: u32,        // next unallocated index
}

slab_allocator_init :: proc(capacity: u32) -> SlabAllocator {
    return SlabAllocator{
        capacity = capacity,
        free_list = make([dynamic]u32, 0),
        next = 0,
    }
}

slab_alloc :: proc(alloc: ^SlabAllocator) -> (index: u32, ok: bool) #optional_ok {
    idx, found := pop_safe(&alloc.free_list)
    if found {
        return idx, found
    }
    if alloc.next < alloc.capacity {
        idx := alloc.next
        alloc.next += 1
        return idx, true
    }
    return idx, found // out of space
}

slab_free :: proc(alloc: ^SlabAllocator, index: u32) {
    append(&alloc.free_list, index)
}