package vulkan_backend

import vk "vendor:vulkan"

// Buffer is shared by the graphics and compute queues. Host-visible buffers are persistently
// mapped at `mapped`; device-local ones (mapped = nil) are written through queue_buffer_write.
Buffer :: struct {
  buffer: vk.Buffer,
  memory: vk.DeviceMemory,
  mapped: [^]u8,
  size:   vk.DeviceSize,
}

// buffer_create allocates a buffer and its memory, persistently mapped when host_visible.
buffer_create :: proc(
  gctx: ^GPUContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  host_visible := true,
  host_cached := false,
) -> (
  buffer: Buffer,
  ret: vk.Result,
) {
  buffer.size = size
  create_info := vk.BufferCreateInfo {
    sType = .BUFFER_CREATE_INFO,
    size  = size,
    usage = usage if host_visible else usage | {.TRANSFER_DST},
  }
  families: [2]u32
  set_sharing(gctx, &create_info, true, &families)
  vk.CreateBuffer(gctx.device, &create_info, nil, &buffer.buffer) or_return
  defer if ret != .SUCCESS do buffer_destroy(gctx.device, &buffer)
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(gctx.device, buffer.buffer, &mem_reqs)
  properties: vk.MemoryPropertyFlags = {.HOST_VISIBLE, .HOST_COHERENT} if host_visible else {.DEVICE_LOCAL}
  if host_visible && host_cached {
    if _, ok := find_memory_type_index(gctx.physical_device, mem_reqs.memoryTypeBits, properties + {.HOST_CACHED}); ok {
      properties += {.HOST_CACHED}
    }
  }
  buffer.memory = allocate_memory(gctx, mem_reqs, properties) or_return
  vk.BindBufferMemory(gctx.device, buffer.buffer, buffer.memory, 0) or_return
  if host_visible {
    vk.MapMemory(gctx.device, buffer.memory, 0, size, {}, auto_cast &buffer.mapped) or_return
  }
  return buffer, .SUCCESS
}

// buffer_info returns descriptor info covering the whole buffer.
buffer_info :: proc(buffer: ^Buffer) -> vk.DescriptorBufferInfo {
  return {buffer = buffer.buffer, range = buffer.size}
}

// buffer_destroy unmaps and frees buffer immediately.
buffer_destroy :: proc(device: vk.Device, buffer: ^Buffer) {
  if buffer.mapped != nil do vk.UnmapMemory(device, buffer.memory)
  vk.DestroyBuffer(device, buffer.buffer, nil)
  vk.FreeMemory(device, buffer.memory, nil)
  buffer^ = {}
}

// mapped views count elements of T from byte offset of a mapped buffer; count < 0 takes every whole element to the end.
mapped :: proc(buffer: ^Buffer, $T: typeid, offset: vk.DeviceSize = 0, count := -1) -> []T {
  count := count
  if count < 0 do count = int((buffer.size - offset) / size_of(T))
  return ([^]T)(&buffer.mapped[offset])[:count]
}

// Trash is a resource that defer_destroy can queue; pool-managed resources retire through their pool instead.
Trash :: union {
  Buffer,
  vk.ImageView,
  vk.Pipeline,
  vk.PipelineLayout,
  vk.DescriptorSetLayout,
  RetiredSet,
}

// RetiredSet is a descriptor set to return to its pool.
RetiredSet :: struct {
  pool: vk.DescriptorPool,
  set:  vk.DescriptorSet,
}

@(private)
TrashItem :: struct {
  ready: u64,
  trash: Trash,
}

// defer_destroy queues trash for destruction RETIRE_GRACE frames later, once no frame in flight can use it.
defer_destroy :: proc(gctx: ^GPUContext, trash: Trash) {
  append(&gctx.trash, TrashItem{gctx.frame_serial + RETIRE_GRACE, trash})
}

@(private = "file")
destroy_item :: proc(device: vk.Device, item: ^TrashItem) {
  switch &t in item.trash {
  case Buffer:
    buffer_destroy(device, &t)
  case vk.ImageView:
    vk.DestroyImageView(device, t, nil)
  case vk.Pipeline:
    vk.DestroyPipeline(device, t, nil)
  case vk.PipelineLayout:
    vk.DestroyPipelineLayout(device, t, nil)
  case vk.DescriptorSetLayout:
    vk.DestroyDescriptorSetLayout(device, t, nil)
  case RetiredSet:
    set := t.set
    vk.FreeDescriptorSets(device, t.pool, 1, &set)
  }
}

// deferred_tick destroys every queued resource whose grace has elapsed. Call once per frame, after wait_frame.
deferred_tick :: proc(gctx: ^GPUContext) {
  i := 0
  for i < len(gctx.trash) {
    if gctx.trash[i].ready > gctx.frame_serial {
      i += 1
      continue
    }
    destroy_item(gctx.device, &gctx.trash[i])
    unordered_remove(&gctx.trash, i)
  }
}

// deferred_flush destroys every queued resource now. Only after vkDeviceWaitIdle.
deferred_flush :: proc(gctx: ^GPUContext) {
  discard_uploads(gctx)
  for &item in gctx.trash do destroy_item(gctx.device, &item)
  clear(&gctx.trash)
}

