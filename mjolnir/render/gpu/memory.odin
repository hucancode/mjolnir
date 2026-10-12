package gpu

import vk "vendor:vulkan"

// A buffer shared by the graphics and compute queues. Host-visible buffers
// are persistently mapped at `mapped`; device-local ones (mapped = nil) are
// written through queue_buffer_write. A host-cached buffer is fast for the CPU
// to read back as well as write, where the device has such memory.
Buffer :: struct {
  buffer: vk.Buffer,
  memory: vk.DeviceMemory,
  mapped: [^]u8,
  size:   vk.DeviceSize,
}

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

// Descriptor info covering the whole buffer.
buffer_info :: proc(buffer: ^Buffer) -> vk.DescriptorBufferInfo {
  return {buffer = buffer.buffer, range = buffer.size}
}

buffer_destroy :: proc(device: vk.Device, buffer: ^Buffer) {
  if buffer.mapped != nil do vk.UnmapMemory(device, buffer.memory)
  vk.DestroyBuffer(device, buffer.buffer, nil)
  vk.FreeMemory(device, buffer.memory, nil)
  buffer^ = {}
}

// `count` elements of `T` from byte `offset` of a mapped buffer; count < 0
// takes every whole element to the end.
mapped :: proc(buffer: ^Buffer, $T: typeid, offset: vk.DeviceSize = 0, count := -1) -> []T {
  count := count
  if count < 0 do count = int((buffer.size - offset) / size_of(T))
  return ([^]T)(&buffer.mapped[offset])[:count]
}

// Deferred GPU-resource destruction. A resource freed at runtime may still be
// read by frames already submitted to the GPU, so destroying its vk handles
// inline is a use-after-free. Instead enqueue the handles; deferred_tick
// destroys them RETIRE_GRACE frames later.
//
// Pool-managed resources (textures, meshes) defer through their pool's
// retirement grace, which also holds back their bindless index. This queue is
// for resources with no owning pool.

// Frames (submissions, counted by frame_serial) a freed GPU resource or pool
// slot waits before it is destroyed or reused: the frames in flight, plus one
// because async compute culls a frame ahead (graphics n+1 draws the lists
// compute n built).
RETIRE_GRACE :: FRAMES_IN_FLIGHT + 1

Trash :: union {
  Buffer,
  vk.ImageView,
}

@(private)
TrashItem :: struct {
  ready: u64,
  trash: Trash,
}

// Queue `trash` for destruction once no frame in flight can use it.
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
  }
}

// deferred_tick destroys every queued resource whose grace has elapsed. Call
// once per frame, after wait_frame.
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

// deferred_flush destroys every queued resource now, ignoring grace. Use only
// after vkDeviceWaitIdle (teardown/shutdown), where no frame is in flight.
deferred_flush :: proc(gctx: ^GPUContext) {
  discard_uploads(gctx)
  for &item in gctx.trash do destroy_item(gctx.device, &item)
  clear(&gctx.trash)
}

