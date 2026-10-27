#+private
package vulkan_backend

import "core:log"
import vk "vendor:vulkan"

// Buffers and images take ranges of large memory blocks: one vkAllocateMemory per block, not
// per resource (allocations are slow and capped by maxMemoryAllocationCount, often 4096).
// Buffers and images keep to blocks of their own, so bufferImageGranularity never applies. A
// host-visible block is mapped once, for as long as it lives; its allocations map inside it.
// Blocks stay until shutdown once made, except dedicated ones, freed with their resource.

// The size of a block, or an eighth of its heap where that is smaller (a 256 MiB BAR heap).
@(private = "file")
BLOCK_SIZE :: vk.DeviceSize(64 * 1024 * 1024)

// Allocation is a range of a block: its index in Allocator.blocks + 1, 0 for none.
Allocation :: struct {
  block:  u32,
  offset: vk.DeviceSize,
  size:   vk.DeviceSize,
}

// A block whose memory is 0 is a freed dedicated one, its entry free for the next block.
@(private)
MemoryBlock :: struct {
  memory:     vk.DeviceMemory,
  size:       vk.DeviceSize,
  mapped:     [^]u8,
  type_index: u32,
  // holds buffers (linear) or images (optimal)
  linear:     bool,
  // one resource at least half a block: freed with it
  dedicated:  bool,
  // free ranges by offset, neighbours merged
  free:       [dynamic]MemoryRange,
}

@(private)
MemoryRange :: struct {
  offset, size: vk.DeviceSize,
}

@(private)
Allocator :: struct {
  blocks:     [dynamic]MemoryBlock,
  properties: vk.PhysicalDeviceMemoryProperties,
}

@(private)
allocator_init :: proc(gctx: ^GPUContext) {
  vk.GetPhysicalDeviceMemoryProperties(gctx.physical_device, &gctx.allocator.properties)
}

// Frees every block; every allocation is gone by then.
@(private)
allocator_destroy :: proc(gctx: ^GPUContext) {
  for &block in gctx.allocator.blocks do if block.memory != 0 do block_free(gctx, &block)
  delete(gctx.allocator.blocks)
}

// memory_alloc takes memory of `properties` meeting reqs, from a block of buffers (linear) or
// images.
memory_alloc :: proc(
  gctx: ^GPUContext,
  reqs: vk.MemoryRequirements,
  properties: vk.MemoryPropertyFlags,
  linear: bool,
) -> (
  a: Allocation,
  ret: vk.Result,
) {
  type_index, found := find_memory_type_index(gctx, reqs.memoryTypeBits, properties)
  if !found do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  s := &gctx.allocator
  heap := s.properties.memoryHeaps[s.properties.memoryTypes[type_index].heapIndex].size
  block_size := min(BLOCK_SIZE, heap / 8)
  if reqs.size >= block_size / 2 {
    index := block_make(gctx, reqs.size, type_index, linear, dedicated = true) or_return
    return range_alloc(s, index, reqs.size, reqs.alignment).?, .SUCCESS
  }
  for &block, i in s.blocks {
    if block.memory == 0 || block.dedicated || block.type_index != type_index || block.linear != linear do continue
    if taken, ok := range_alloc(s, u32(i), reqs.size, reqs.alignment).?; ok do return taken, .SUCCESS
  }
  index := block_make(gctx, block_size, type_index, linear, dedicated = false) or_return
  return range_alloc(s, index, reqs.size, reqs.alignment).?, .SUCCESS
}

// memory_free returns `a` to its block at once: the caller has waited out its last use.
memory_free :: proc(gctx: ^GPUContext, a: ^Allocation) {
  if a.block == 0 do return
  block := &gctx.allocator.blocks[a.block - 1]
  r := MemoryRange{a.offset, a.size}
  a^ = {}
  if block.dedicated {
    block_free(gctx, block)
    return
  }
  range_free(block, r)
}

// The memory of `a`'s block.
allocation_memory :: proc(gctx: ^GPUContext, a: Allocation) -> vk.DeviceMemory {
  return gctx.allocator.blocks[a.block - 1].memory
}

// The mapping of `a`, nil unless host visible.
allocation_mapped :: proc(gctx: ^GPUContext, a: Allocation) -> [^]u8 {
  if a.block == 0 do return nil
  mapped := gctx.allocator.blocks[a.block - 1].mapped
  return nil if mapped == nil else mapped[a.offset:]
}

// Takes the entry of a freed dedicated block, or a new one.
@(private = "file")
block_make :: proc(gctx: ^GPUContext, size: vk.DeviceSize, type_index: u32, linear, dedicated: bool) -> (index: u32, ret: vk.Result) {
  info := vk.MemoryAllocateInfo {
    sType           = .MEMORY_ALLOCATE_INFO,
    allocationSize  = size,
    memoryTypeIndex = type_index,
  }
  memory: vk.DeviceMemory
  vk.AllocateMemory(gctx.device, &info, nil, &memory) or_return
  block := MemoryBlock{memory = memory, size = size, type_index = type_index, linear = linear, dedicated = dedicated}
  append(&block.free, MemoryRange{0, size})
  if .HOST_VISIBLE in gctx.allocator.properties.memoryTypes[type_index].propertyFlags {
    if res := vk.MapMemory(gctx.device, memory, 0, size, {}, auto_cast &block.mapped); res != .SUCCESS {
      block_free(gctx, &block)
      return 0, res
    }
  }
  blocks := &gctx.allocator.blocks
  index = u32(len(blocks))
  for b, i in blocks do if b.memory == 0 {
    index = u32(i)
    break
  }
  if int(index) == len(blocks) do append(blocks, block)
  else do blocks[index] = block
  if !dedicated do log.debugf("Memory block of %d MiB, type %d", size >> 20, type_index)
  return index, .SUCCESS
}

// Frees the block's memory; its entry stays, free for the next block.
@(private = "file")
block_free :: proc(gctx: ^GPUContext, block: ^MemoryBlock) {
  if block.mapped != nil do vk.UnmapMemory(gctx.device, block.memory)
  vk.FreeMemory(gctx.device, block.memory, nil)
  delete(block.free)
  block^ = {}
}

// First fit; what alignment skips stays free.
@(private = "file")
range_alloc :: proc(allocator: ^Allocator, index: u32, size, alignment: vk.DeviceSize) -> Maybe(Allocation) {
  block := &allocator.blocks[index]
  align := max(alignment, 1)
  for r, i in block.free {
    start := (r.offset + align - 1) / align * align
    if start + size > r.offset + r.size do continue
    before := MemoryRange{r.offset, start - r.offset}
    after := MemoryRange{start + size, r.offset + r.size - start - size}
    ordered_remove(&block.free, i)
    if after.size > 0 do inject_at(&block.free, i, after)
    if before.size > 0 do inject_at(&block.free, i, before)
    return Allocation{block = index + 1, offset = start, size = size}
  }
  return nil
}

@(private = "file")
range_free :: proc(block: ^MemoryBlock, r: MemoryRange) {
  i := 0
  for i < len(block.free) && block.free[i].offset < r.offset do i += 1
  inject_at(&block.free, i, r)
  // merge with the next, then the previous
  if i + 1 < len(block.free) && block.free[i].offset + block.free[i].size == block.free[i + 1].offset {
    block.free[i].size += block.free[i + 1].size
    ordered_remove(&block.free, i + 1)
  }
  if i > 0 && block.free[i - 1].offset + block.free[i - 1].size == block.free[i].offset {
    block.free[i - 1].size += block.free[i].size
    ordered_remove(&block.free, i)
  }
}
