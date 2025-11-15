package gpu

import "core:log"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

MutableBuffer :: struct($T: typeid) {
  buffer:       vk.Buffer,
  memory:       vk.DeviceMemory,
  mapped:       [^]T,
  element_size: int,
  bytes_count:  int,
}

ImmutableBuffer :: struct($T: typeid) {
  buffer:       vk.Buffer,
  memory:       vk.DeviceMemory,
  element_size: int,
  bytes_count:  int,
}

malloc_mutable_buffer :: proc(
  gctx: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  buffer: MutableBuffer(T),
  ret: vk.Result,
) {
  if .UNIFORM_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(gctx.device_properties.limits.minUniformBufferOffsetAlignment),
    )
  } else {
    buffer.element_size = size_of(T)
  }
  buffer.bytes_count = buffer.element_size * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(buffer.bytes_count),
    usage       = usage,
    sharingMode = .EXCLUSIVE,
  }
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
  log.infof("mutable buffer created 0x%x at %v", buffer.buffer, &buffer.mapped)
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
  if .UNIFORM_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(gctx.device_properties.limits.minUniformBufferOffsetAlignment),
    )
  } else {
    buffer.element_size = size_of(T)
  }
  buffer.bytes_count = buffer.element_size * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(buffer.bytes_count),
    usage       = usage | {.TRANSFER_DST},
    sharingMode = .EXCLUSIVE,
  }
  vk.CreateBuffer(gctx.device, &create_info, nil, &buffer.buffer) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(gctx.device, buffer.buffer, &mem_reqs)
  buffer.memory = allocate_memory(gctx, mem_reqs, {.DEVICE_LOCAL}) or_return
  vk.BindBufferMemory(gctx.device, buffer.buffer, buffer.memory, 0) or_return
  log.infof("immutable buffer created 0x%x", buffer.buffer)
  return buffer, .SUCCESS
}

@(private = "file")
align_up :: proc(value: int, alignment: int) -> int {
  return (value + alignment - 1) & ~(alignment - 1)
}

get :: proc {
  mutable_buffer_get,
}

get_all :: proc {
  mutable_buffer_get_all,
  buffer_get_all,
}

write :: proc {
  mutable_buffer_write,
  mutable_buffer_write_multi,
  buffer_write,
  buffer_write_multi,
}

mutable_buffer_write :: proc(
  buffer: ^MutableBuffer($T),
  data: ^T,
  index: int = 0,
) -> vk.Result {
  if buffer.mapped == nil do return .ERROR_UNKNOWN
  offset := index * buffer.element_size
  if offset + buffer.element_size > buffer.bytes_count do return .ERROR_UNKNOWN
  destination := mem.ptr_offset(cast([^]u8)buffer.mapped, offset)
  mem.copy(destination, data, size_of(T))
  return .SUCCESS
}

mutable_buffer_write_multi :: proc(
  buffer: ^MutableBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  if buffer.mapped == nil do return .ERROR_UNKNOWN
  offset := index * buffer.element_size
  if offset + buffer.element_size * len(data) > buffer.bytes_count do return .ERROR_UNKNOWN
  destination := mem.ptr_offset(cast([^]u8)buffer.mapped, offset)
  mem.copy(destination, raw_data(data), slice.size(data))
  return .SUCCESS
}

mutable_buffer_get :: proc(buffer: ^MutableBuffer($T), index: u32 = 0) -> ^T {
  return &buffer.mapped[index]
}

mutable_buffer_get_all :: proc(buffer: ^MutableBuffer($T)) -> []T {
  element_count := buffer.bytes_count / buffer.element_size
  return slice.from_ptr(buffer.mapped, element_count)
}

mutable_buffer_destroy :: proc(device: vk.Device, buffer: ^MutableBuffer($T)) {
  if buffer.mapped != nil {
    vk.UnmapMemory(device, buffer.memory)
    buffer.mapped = nil
  }
  vk.DestroyBuffer(device, buffer.buffer, nil)
  buffer.buffer = 0
  vk.FreeMemory(device, buffer.memory, nil)
  buffer.memory = 0
  buffer.bytes_count = 0
  buffer.element_size = 0
}

buffer_write :: proc(
  gctx: ^GPUContext,
  buffer: ^ImmutableBuffer($T),
  data: ^T,
  index: int = 0,
) -> vk.Result {
  staging := malloc_mutable_buffer(gctx, T, 1, {.TRANSFER_SRC}) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  mutable_buffer_write(&staging, data) or_return
  cmd_buffer := begin_single_time_command(gctx) or_return
  offset := vk.DeviceSize(index * buffer.element_size)
  region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = offset,
    size      = vk.DeviceSize(buffer.element_size),
  }
  vk.CmdCopyBuffer(cmd_buffer, staging.buffer, buffer.buffer, 1, &region)
  return end_single_time_command(gctx, &cmd_buffer)
}

buffer_write_multi :: proc(
  gctx: ^GPUContext,
  buffer: ^ImmutableBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  staging := malloc_mutable_buffer(
    gctx,
    T,
    len(data),
    {.TRANSFER_SRC},
  ) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  mutable_buffer_write_multi(&staging, data) or_return
  cmd_buffer := begin_single_time_command(gctx) or_return
  offset := vk.DeviceSize(index * buffer.element_size)
  region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = offset,
    size      = vk.DeviceSize(buffer.element_size * len(data)),
  }
  vk.CmdCopyBuffer(cmd_buffer, staging.buffer, buffer.buffer, 1, &region)
  return end_single_time_command(gctx, &cmd_buffer)
}

buffer_get_all :: proc(
  gctx: ^GPUContext,
  buffer: ^ImmutableBuffer($T),
  output: []T,
  index: int = 0,
) -> vk.Result {
  if len(output) == 0 do return .SUCCESS
  staging := malloc_mutable_buffer(
    gctx,
    T,
    len(output),
    {.TRANSFER_DST},
  ) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  cmd_buffer := begin_single_time_command(gctx) or_return
  offset := vk.DeviceSize(index * buffer.element_size)
  region := vk.BufferCopy {
    srcOffset = offset,
    dstOffset = 0,
    size      = vk.DeviceSize(buffer.element_size * len(output)),
  }
  vk.CmdCopyBuffer(cmd_buffer, buffer.buffer, staging.buffer, 1, &region)
  end_single_time_command(gctx, &cmd_buffer) or_return
  for i in 0 ..< len(output) {
    output[i] = staging.mapped[i]
  }
  return .SUCCESS
}

buffer_destroy :: proc(device: vk.Device, buffer: ^ImmutableBuffer($T)) {
  vk.DestroyBuffer(device, buffer.buffer, nil)
  buffer.buffer = 0
  vk.FreeMemory(device, buffer.memory, nil)
  buffer.memory = 0
  buffer.bytes_count = 0
  buffer.element_size = 0
}

create_mutable_buffer :: proc(
  gctx: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: MutableBuffer(T),
  ret: vk.Result,
) {
  buffer = malloc_mutable_buffer(gctx, T, count, usage) or_return
  if data != nil do mem.copy(buffer.mapped, data, buffer.bytes_count)
  return buffer, .SUCCESS
}

CubeImage:: struct {
  using base: Image,
  face_views: [6]vk.ImageView, // One view per face for rendering
}

cube_depth_texture_init :: proc(
  gctx: ^GPUContext,
  self: ^CubeImage,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> vk.Result {
  spec := image_spec_cube(size, format, usage)
  self.base = image_create(gctx, spec) or_return
  // Create 6 face views (one per face for rendering to individual faces)
  for i in 0 ..< 6 {
    view_info := vk.ImageViewCreateInfo {
      sType = .IMAGE_VIEW_CREATE_INFO,
      image = self.image,
      viewType = .D2,
      format = format,
      components = {
        r = .IDENTITY,
        g = .IDENTITY,
        b = .IDENTITY,
        a = .IDENTITY,
      },
      subresourceRange = {
        aspectMask = self.spec.aspect_mask,
        levelCount = 1,
        baseArrayLayer = u32(i),
        layerCount = 1,
      },
    }
    vk.CreateImageView(
      gctx.device,
      &view_info,
      nil,
      &self.face_views[i],
    ) or_return
  }
  return .SUCCESS
}

cube_depth_texture_destroy :: proc(device: vk.Device, self: ^CubeImage) {
  if self == nil {
    return
  }
  for &v in self.face_views {
    vk.DestroyImageView(device, v, nil)
    v = 0
  }
  image_destroy(device, &self.base)
}

immutable_buffer_info :: proc(self: ^ImmutableBuffer($T)) -> vk.DescriptorBufferInfo {
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
