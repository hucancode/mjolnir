package containers

// MAX_SLAB_CLASSES is the maximum number of slab size classes.
MAX_SLAB_CLASSES :: 8

// SlabConfig is a block size and block count per size class; unused classes are zero.
SlabConfig :: [MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
}

// SlabAllocator is a multi-size memory allocator for index-based allocation.
// It maintains multiple "slabs" of different block sizes for efficient allocation.
// All classes share one contiguous index range.
SlabAllocator :: struct {
  classes:  [MAX_SLAB_CLASSES]struct {
    block_size:  u32, // Size of each block in this class
    block_count: u32, // Total blocks available in this class
    free_list:   [dynamic]u32, // Recycled indices
    next:        u32, // Next fresh index to allocate
    base:        u32, // Base index for this class
    mark:        u32, // slab_rewind frees every block from here on
  },
  capacity: u32, // Total capacity across all classes
}

// slab_init initializes the slab allocator with the given size class configuration.
// Each class has a block_size and block_count.
slab_init :: proc(allocator: ^SlabAllocator, config: SlabConfig) {
  base := u32(0)
  for c, i in config {
    allocator.classes[i] = {
      block_size  = c.block_size,
      block_count = c.block_count,
      free_list   = make([dynamic]u32, 0, c.block_count),
      next        = base,
      base        = base,
      mark        = base,
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
// Returns (index, ok). The index is in the shared index range.
slab_alloc :: proc(
  allocator: ^SlabAllocator,
  count: u32,
) -> (
  index: u32,
  ok: bool,
) #optional_ok {
  if count == 0 do return 0, true
  for &class in allocator.classes do if class.block_size >= count {
    if len(class.free_list) > 0 {
      idx := pop(&class.free_list)
      return idx, true
    }
    if class.next < class.base + class.block_size * class.block_count {
      defer class.next += class.block_size
      return class.next, true
    }
  }
  return 0, false
}

// slab_free returns an index to the free list for later reuse; an index no class holds
// (a zero-size allocation) is ignored.
slab_free :: proc(allocator: ^SlabAllocator, index: u32) {
  for &class in allocator.classes {
    if index >= class.base && index < class.base + class.block_size * class.block_count {
      append(&class.free_list, index)
      return
    }
  }
}

// slab_mark keeps every block allocated so far through slab_rewind.
slab_mark :: proc(allocator: ^SlabAllocator) {
  for &class in allocator.classes do class.mark = class.next
}

// slab_rewind frees every block allocated since slab_mark (since slab_init without one) at once.
slab_rewind :: proc(allocator: ^SlabAllocator) {
  for &class in allocator.classes {
    n := 0
    for i in class.free_list do if i < class.mark {class.free_list[n] = i; n += 1}
    resize(&class.free_list, n)
    class.next = class.mark
  }
}

// slab_block_size returns the capacity of the block at `index`; 0 when no class holds it.
slab_block_size :: proc(allocator: ^SlabAllocator, index: u32) -> u32 {
  for class in allocator.classes {
    if index >= class.base && index < class.base + class.block_size * class.block_count do return class.block_size
  }
  return 0
}
