package resource

MAX_SLAB_CLASSES :: 8

SlabAllocator :: struct {
  classes:        [MAX_SLAB_CLASSES]struct {
    block_size:  u32,
    block_count: u32,
    // All indices are in the global resource array space
    free_list:   [dynamic]u32,
    next:        u32,
    base:        u32,
  },
  capacity: u32,
}

make_slab_allocator :: proc(config: [MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  }) -> SlabAllocator {
  ret: SlabAllocator
  base := u32(0)
  for c, i in config {
    ret.classes[i] = {
      block_size  = c.block_size,
      block_count = c.block_count,
      free_list   = make([dynamic]u32, 0, c.block_count),
      next        = base,
      base        = base,
    }
    base += c.block_size * c.block_count
  }
  ret.capacity = base
  return ret
}

slab_alloc :: proc(
  self: ^SlabAllocator,
  count: u32,
) -> (
  index: u32,
  ok: bool,
) #optional_ok {
  for &class in self.classes {
    if class.block_size < count {
      continue
    }
    idx, found := pop_safe(&class.free_list)
    if found {
      return idx, true
    }
    if class.next < class.block_count {
      defer class.next += class.block_size
      return class.next, true
    }
  }
  return 0, false
}

slab_free :: proc(self: ^SlabAllocator, index: u32) {
  for &class in self.classes {
    if index < class.base {
      continue
    }
    if index >= class.base + class.block_size * class.block_count {
      break
    }
    append(&class.free_list, index)
    return
  }
}
