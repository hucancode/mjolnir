package gpu

import vk "vendor:vulkan"

// Host-visible, persistently mapped buffer of `T`.
MutableBuffer :: struct($T: typeid) {
  buffer:      vk.Buffer,
  memory:      vk.DeviceMemory,
  mapped:      [^]T,
  bytes_count: int,
}

// Device-local buffer of `T`, written through staging copies.
ImmutableBuffer :: struct($T: typeid) {
  buffer:      vk.Buffer,
  memory:      vk.DeviceMemory,
  bytes_count: int,
}

create_mutable_buffer :: proc(
  gctx: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  buffer: MutableBuffer(T),
  ret: vk.Result,
) {
  buffer.bytes_count = size_of(T) * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(buffer.bytes_count),
    usage       = usage,
  }
  families: [2]u32
  set_sharing(gctx, &create_info, true, &families)
  vk.CreateBuffer(gctx.device, &create_info, nil, &buffer.buffer) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(gctx.device, buffer.buffer, &mem_reqs)
  buffer.memory = allocate_memory(
    gctx,
    mem_reqs,
    {.HOST_VISIBLE, .HOST_COHERENT},
  ) or_return
  vk.BindBufferMemory(gctx.device, buffer.buffer, buffer.memory, 0) or_return
  vk.MapMemory(
    gctx.device,
    buffer.memory,
    0,
    vk.DeviceSize(buffer.bytes_count),
    {},
    auto_cast &buffer.mapped,
  ) or_return
  return buffer, .SUCCESS
}

malloc_buffer :: proc(
  gctx: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  buffer: ImmutableBuffer(T),
  ret: vk.Result,
) {
  buffer.bytes_count = size_of(T) * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(buffer.bytes_count),
    usage       = usage | {.TRANSFER_DST},
  }
  families: [2]u32
  set_sharing(gctx, &create_info, true, &families)
  vk.CreateBuffer(gctx.device, &create_info, nil, &buffer.buffer) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(gctx.device, buffer.buffer, &mem_reqs)
  buffer.memory = allocate_memory(gctx, mem_reqs, {.DEVICE_LOCAL}) or_return
  vk.BindBufferMemory(gctx.device, buffer.buffer, buffer.memory, 0) or_return
  return buffer, .SUCCESS
}

get :: proc(buffer: ^MutableBuffer($T), index: u32 = 0) -> ^T {
  return &buffer.mapped[index]
}

get_all :: proc(buffer: ^MutableBuffer($T)) -> []T {
  return buffer.mapped[:buffer.bytes_count / size_of(T)]
}

write :: proc {
  mutable_buffer_write,
  buffer_write_multi,
}

mutable_buffer_write :: proc(
  buffer: ^MutableBuffer($T),
  data: ^T,
  index: int = 0,
) {
  get_all(buffer)[index] = data^
}

mutable_buffer_destroy :: proc(device: vk.Device, buffer: ^MutableBuffer($T)) {
  if buffer.mapped != nil do vk.UnmapMemory(device, buffer.memory)
  vk.DestroyBuffer(device, buffer.buffer, nil)
  vk.FreeMemory(device, buffer.memory, nil)
  buffer^ = {}
}

// Copy `data` into `buffer` starting at element `index` through a staging
// buffer; blocks until the copy completes.
buffer_write_multi :: proc(
  gctx: ^GPUContext,
  buffer: ^ImmutableBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  staging := create_mutable_buffer(gctx, T, len(data), {.TRANSFER_SRC}) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  copy(get_all(&staging), data)
  cmd_buffer := begin_single_time_command(gctx) or_return
  region := vk.BufferCopy {
    dstOffset = vk.DeviceSize(index * size_of(T)),
    size      = vk.DeviceSize(staging.bytes_count),
  }
  vk.CmdCopyBuffer(cmd_buffer, staging.buffer, buffer.buffer, 1, &region)
  return end_single_time_command(gctx, &cmd_buffer)
}

buffer_destroy :: proc(device: vk.Device, buffer: ^ImmutableBuffer($T)) {
  vk.DestroyBuffer(device, buffer.buffer, nil)
  vk.FreeMemory(device, buffer.memory, nil)
  buffer^ = {}
}

immutable_buffer_info :: proc(
  self: ^ImmutableBuffer($T),
) -> vk.DescriptorBufferInfo {
  return vk.DescriptorBufferInfo {
    buffer = self.buffer,
    range = vk.DeviceSize(self.bytes_count),
  }
}

mutable_buffer_info :: proc(
  self: ^MutableBuffer($T),
) -> vk.DescriptorBufferInfo {
  return vk.DescriptorBufferInfo {
    buffer = self.buffer,
    range = vk.DeviceSize(self.bytes_count),
  }
}

buffer_info :: proc {
  immutable_buffer_info,
  mutable_buffer_info,
}

// Storage buffer with the descriptor set that binds it.
BindlessBuffer :: struct($T: typeid) {
  buffer:         MutableBuffer(T),
  set_layout:     vk.DescriptorSetLayout,
  descriptor_set: vk.DescriptorSet,
}

// One storage buffer and descriptor set per frame in flight.
PerFrameBindlessBuffer :: struct($T: typeid) {
  buffers:         [FRAMES_IN_FLIGHT]MutableBuffer(T),
  set_layout:      vk.DescriptorSetLayout,
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

bindless_buffer_init :: proc(
  self: ^BindlessBuffer($T),
  gctx: ^GPUContext,
  capacity: int,
  stages: vk.ShaderStageFlags,
) -> (
  ret: vk.Result,
) {
  self.buffer = create_mutable_buffer(gctx, T, capacity, {.STORAGE_BUFFER}) or_return
  self.set_layout = create_descriptor_set_layout(gctx, {.STORAGE_BUFFER, stages}) or_return
  self.descriptor_set = create_descriptor_set(
    gctx,
    &self.set_layout,
    {.STORAGE_BUFFER, buffer_info(&self.buffer)},
  ) or_return
  return .SUCCESS
}

bindless_buffer_destroy :: proc(self: ^BindlessBuffer($T), gctx: ^GPUContext) {
  free_descriptor_sets(gctx, self.descriptor_set)
  mutable_buffer_destroy(gctx.device, &self.buffer)
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self^ = {}
}

per_frame_bindless_buffer_init :: proc(
  self: ^PerFrameBindlessBuffer($T),
  gctx: ^GPUContext,
  capacity: int,
  stages: vk.ShaderStageFlags,
) -> (
  ret: vk.Result,
) {
  self.set_layout = create_descriptor_set_layout(gctx, {.STORAGE_BUFFER, stages}) or_return
  for &b, i in self.buffers {
    b = create_mutable_buffer(gctx, T, capacity, {.STORAGE_BUFFER}) or_return
    self.descriptor_sets[i] = create_descriptor_set(
      gctx,
      &self.set_layout,
      {.STORAGE_BUFFER, buffer_info(&b)},
    ) or_return
  }
  return .SUCCESS
}

// Replace frame `frame`'s buffer with an empty one of `capacity` elements
// and point its descriptor set at it. The caller guarantees no submitted work
// still uses that frame's buffer or set.
per_frame_bindless_buffer_resize :: proc(
  self: ^PerFrameBindlessBuffer($T),
  gctx: ^GPUContext,
  frame: u32,
  capacity: int,
) -> vk.Result {
  grown := create_mutable_buffer(gctx, T, capacity, {.STORAGE_BUFFER}) or_return
  mutable_buffer_destroy(gctx.device, &self.buffers[frame])
  self.buffers[frame] = grown
  update_descriptor_set(
    gctx,
    self.descriptor_sets[frame],
    {.STORAGE_BUFFER, buffer_info(&self.buffers[frame])},
  )
  return .SUCCESS
}

per_frame_bindless_buffer_destroy :: proc(
  self: ^PerFrameBindlessBuffer($T),
  gctx: ^GPUContext,
) {
  free_descriptor_sets(gctx, ..self.descriptor_sets[:])
  for &b in self.buffers do mutable_buffer_destroy(gctx.device, &b)
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self^ = {}
}
