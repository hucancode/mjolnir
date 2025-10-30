package containers

// MAX_SLAB_CLASSES is the maximum number of slab size classes.
MAX_SLAB_CLASSES :: 8

// SlabAllocator is a multi-size memory allocator for index-based allocation.
// It maintains multiple "slabs" of different block sizes for efficient allocation.
// All indices are in a global resource array space.
SlabAllocator :: struct {
	classes: [MAX_SLAB_CLASSES]struct {
		block_size:  u32, // Size of each block in this class
		block_count: u32, // Total blocks available in this class
		free_list:   [dynamic]u32, // Recycled indices
		next:        u32, // Next fresh index to allocate
		base:        u32, // Base index for this class
	},
	capacity: u32, // Total capacity across all classes
}

// slab_init initializes the slab allocator with the given size class configuration.
// Each class has a block_size and block_count.
slab_init :: proc(
	allocator: ^SlabAllocator,
	config: [MAX_SLAB_CLASSES]struct {
		block_size, block_count: u32,
	},
) {
	base := u32(0)
	for c, i in config {
		allocator.classes[i] = {
			block_size  = c.block_size,
			block_count = c.block_count,
			free_list   = make([dynamic]u32, 0, c.block_count),
			next        = base,
			base        = base,
		}
		base += c.block_size * c.block_count
	}
	allocator.capacity = base
}

// slab_destroy frees the slab allocator's internal memory.
slab_destroy :: proc(allocator: ^SlabAllocator) {
	for &class in allocator.classes do delete(class.free_list)
}

// slab_alloc allocates a block large enough to hold count items.
// Returns (index, ok). The index is in the global resource space.
slab_alloc :: proc(
	allocator: ^SlabAllocator,
	count: u32,
) -> (
	index: u32,
	ok: bool,
) #optional_ok {
	// Find the first class that can fit count items
	for &class in allocator.classes do if class.block_size >= count {
		// Try recycled indices first
		if len(class.free_list) > 0 {
			idx := pop(&class.free_list)
			return idx, true
		}
		// Allocate a fresh index if space available
		if class.next < class.base + class.block_size * class.block_count {
			defer class.next += class.block_size
			return class.next, true
		}
	}
	return 0, false
}

// slab_free returns an index to the free list for later reuse.
slab_free :: proc(allocator: ^SlabAllocator, index: u32) {
	// Find which class this index belongs to
	for &class in allocator.classes do if index >= class.base {
		if index >= class.base + class.block_size * class.block_count {
			break
		}
		append(&class.free_list, index)
		break
	}
}
