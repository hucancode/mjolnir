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
  } else if .STORAGE_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(gctx.device_properties.limits.minStorageBufferOffsetAlignment),
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
  buffer.memory = allocate_vulkan_memory(
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

malloc_immutable_buffer :: proc(
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
  } else if .STORAGE_BUFFER in usage && count > 1 {
    buffer.element_size = align_up(
      size_of(T),
      int(gctx.device_properties.limits.minStorageBufferOffsetAlignment),
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
  buffer.memory = allocate_vulkan_memory(
    gctx,
    mem_reqs,
    {.DEVICE_LOCAL},
  ) or_return
  vk.BindBufferMemory(gctx.device, buffer.buffer, buffer.memory, 0) or_return
  log.infof("immutable buffer created 0x%x", buffer.buffer)
  return buffer, .SUCCESS
}

@(private = "file")
align_up :: proc(value: int, alignment: int) -> int {
  return (value + alignment - 1) & ~(alignment - 1)
}

write :: proc {
  mutable_buffer_write_single,
  mutable_buffer_write_multi,
  immutable_buffer_write_single,
  immutable_buffer_write_multi,
}

mutable_buffer_write_single :: proc(
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

mutable_buffer_offset_of :: proc(
  buffer: ^MutableBuffer($T),
  index: u32,
) -> u32 {
  return index * u32(buffer.element_size)
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

immutable_buffer_write_single :: proc(
  gctx: ^GPUContext,
  buffer: ^ImmutableBuffer($T),
  data: ^T,
  index: int = 0,
) -> vk.Result {
  staging := malloc_mutable_buffer(gctx, T, 1, {.TRANSFER_SRC}) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  mutable_buffer_write_single(&staging, data) or_return
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

immutable_buffer_write_multi :: proc(
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

immutable_buffer_offset_of :: proc(
  buffer: ^ImmutableBuffer($T),
  index: u32,
) -> u32 {
  return index * u32(buffer.element_size)
}

immutable_buffer_read :: proc(
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

immutable_buffer_destroy :: proc(
  device: vk.Device,
  buffer: ^ImmutableBuffer($T),
) {
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
  if data != nil {
    mem.copy(buffer.mapped, data, buffer.bytes_count)
  }
  return buffer, .SUCCESS
}

create_immutable_buffer :: proc(
  gctx: ^GPUContext,
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: ImmutableBuffer(T),
  ret: vk.Result,
) {
  buffer = malloc_immutable_buffer(gctx, T, count, usage) or_return
  if data == nil do return buffer, .SUCCESS
  staging := malloc_mutable_buffer(gctx, T, count, {.TRANSFER_SRC}) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  mem.copy(staging.mapped, data, staging.bytes_count)
  cmd_buffer := begin_single_time_command(gctx) or_return
  region := vk.BufferCopy {
    size = vk.DeviceSize(staging.bytes_count),
  }
  vk.CmdCopyBuffer(cmd_buffer, staging.buffer, buffer.buffer, 1, &region)
  log.infof(
    "Copying staging 0x%x to immutable 0x%x",
    staging.buffer,
    buffer.buffer,
  )
  end_single_time_command(gctx, &cmd_buffer) or_return
  return buffer, .SUCCESS
}
malloc_image_buffer :: proc(
  gctx: ^GPUContext,
  width, height: u32,
  format: vk.Format,
  tiling: vk.ImageTiling,
  usage: vk.ImageUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
) -> (
  img_buffer: ImageBuffer,
  ret: vk.Result,
) {
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {width, height, 1},
    mipLevels     = 1,
    arrayLayers   = 1,
    format        = format,
    tiling        = tiling,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
  }
  vk.CreateImage(gctx.device, &create_info, nil, &img_buffer.image) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(gctx.device, img_buffer.image, &mem_reqs)
  img_buffer.memory = allocate_vulkan_memory(
    gctx,
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindImageMemory(
    gctx.device,
    img_buffer.image,
    img_buffer.memory,
    0,
  ) or_return
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = format
  return img_buffer, .SUCCESS
}

ImageBuffer :: struct {
  image:         vk.Image,
  memory:        vk.DeviceMemory,
  width, height: u32,
  format:        vk.Format,
  view:          vk.ImageView,
}

image_buffer_destroy :: proc(device: vk.Device, self: ^ImageBuffer) {
  vk.DestroyImageView(device, self.view, nil)
  self.view = 0
  vk.DestroyImage(device, self.image, nil)
  self.image = 0
  vk.FreeMemory(device, self.memory, nil)
  self.memory = 0
  self.width = 0
  self.height = 0
  self.format = .UNDEFINED
}

create_image_view :: proc(
  device: vk.Device,
  image: vk.Image,
  format: vk.Format,
  aspect_mask: vk.ImageAspectFlags,
) -> (
  view: vk.ImageView,
  res: vk.Result,
) {
  create_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = image,
    viewType = .D2,
    format = format,
    components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
    subresourceRange = {
      aspectMask = aspect_mask,
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  res = vk.CreateImageView(device, &create_info, nil, &view)
  return
}

copy_image :: proc(
  gctx: ^GPUContext,
  dst: ImageBuffer,
  src: MutableBuffer(u8),
) -> vk.Result {
  cmd_buffer := begin_single_time_command(gctx) or_return
  // Transition image from UNDEFINED to TRANSFER_DST_OPTIMAL
  barrier_to_dst := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {},
    dstAccessMask = {.TRANSFER_WRITE},
    oldLayout = .UNDEFINED,
    newLayout = .TRANSFER_DST_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = dst.image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TOP_OF_PIPE},
    {.TRANSFER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier_to_dst,
  )
  // Copy buffer to image
  region := vk.BufferImageCopy {
    bufferOffset = 0,
    bufferRowLength = 0,
    bufferImageHeight = 0,
    imageSubresource = {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    imageOffset = {0, 0, 0},
    imageExtent = {dst.width, dst.height, 1},
  }
  vk.CmdCopyBufferToImage(
    cmd_buffer,
    src.buffer,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )
  // Transition image from TRANSFER_DST_OPTIMAL to SHADER_READ_ONLY_OPTIMAL
  barrier_to_shader := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.TRANSFER_WRITE},
    dstAccessMask = {.SHADER_READ},
    oldLayout = .TRANSFER_DST_OPTIMAL,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = dst.image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TRANSFER},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier_to_shader,
  )
  return end_single_time_command(gctx, &cmd_buffer)
}

// Copy image but leave in TRANSFER_DST_OPTIMAL for mip generation
copy_image_for_mips :: proc(
  gctx: ^GPUContext,
  dst: ImageBuffer,
  src: MutableBuffer(u8),
) -> vk.Result {
  cmd_buffer := begin_single_time_command(gctx) or_return
  // Transition image from UNDEFINED to TRANSFER_DST_OPTIMAL
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {},
    dstAccessMask = {.TRANSFER_WRITE},
    oldLayout = .UNDEFINED,
    newLayout = .TRANSFER_DST_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = dst.image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TOP_OF_PIPE},
    {.TRANSFER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  // Copy buffer to image
  region := vk.BufferImageCopy {
    bufferOffset = 0,
    bufferRowLength = 0,
    bufferImageHeight = 0,
    imageSubresource = {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    imageOffset = {0, 0, 0},
    imageExtent = {dst.width, dst.height, 1},
  }
  vk.CmdCopyBufferToImage(
    cmd_buffer,
    src.buffer,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )
  // Don't transition to SHADER_READ_ONLY - leave in TRANSFER_DST_OPTIMAL for mip generation
  return end_single_time_command(gctx, &cmd_buffer)
}

create_image_buffer :: proc(
  gctx: ^GPUContext,
  data: rawptr,
  size: vk.DeviceSize,
  format: vk.Format,
  width, height: u32,
) -> (
  img: ImageBuffer,
  ret: vk.Result,
) {
  staging := create_mutable_buffer(
    gctx,
    u8,
    int(size),
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  img = malloc_image_buffer(
    gctx,
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  copy_image(gctx, img, staging) or_return
  aspect_mask := vk.ImageAspectFlags{.COLOR}
  img.view = create_image_view(
    gctx.device,
    img.image,
    format,
    aspect_mask,
  ) or_return
  ret = .SUCCESS
  return
}

depth_image_init :: proc(
  gctx: ^GPUContext,
  img_buffer: ^ImageBuffer,
  width, height: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT},
) -> vk.Result {
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = format
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {width, height, 1},
    mipLevels     = 1,
    arrayLayers   = 1,
    format        = img_buffer.format,
    tiling        = .OPTIMAL,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
  }
  vk.CreateImage(gctx.device, &create_info, nil, &img_buffer.image) or_return
  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(
    gctx.device,
    img_buffer.image,
    &mem_requirements,
  )
  memory_type_index, found := find_memory_type_index(
    gctx.physical_device,
    mem_requirements.memoryTypeBits,
    {.DEVICE_LOCAL},
  )
  if !found {
    return .ERROR_UNKNOWN
  }
  alloc_info := vk.MemoryAllocateInfo {
    sType           = .MEMORY_ALLOCATE_INFO,
    allocationSize  = mem_requirements.size,
    memoryTypeIndex = memory_type_index,
  }
  vk.AllocateMemory(
    gctx.device,
    &alloc_info,
    nil,
    &img_buffer.memory,
  ) or_return
  vk.BindImageMemory(gctx.device, img_buffer.image, img_buffer.memory, 0)
  cmd_buffer := begin_single_time_command(gctx) or_return
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = .UNDEFINED,
    newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = img_buffer.image,
    subresourceRange = {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = {}, // No source access needed for UNDEFINED -> WRITE
    dstAccessMask = {
      .DEPTH_STENCIL_ATTACHMENT_READ,
      .DEPTH_STENCIL_ATTACHMENT_WRITE,
    },
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS}, // Corrected enum value (or LATE_FRAGMENT_TESTS depending on usage)
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  end_single_time_command(gctx, &cmd_buffer) or_return
  img_buffer.view = create_image_view(
    gctx.device,
    img_buffer.image,
    img_buffer.format,
    {.DEPTH},
  ) or_return
  return .SUCCESS
}

CubeImageBuffer :: struct {
  using base: Image,
  face_views: [6]vk.ImageView, // One view per face for rendering
}

cube_depth_texture_init :: proc(
  gctx: ^GPUContext,
  self: ^CubeImageBuffer,
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
        baseMipLevel = 0,
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

cube_depth_texture_destroy :: proc(device: vk.Device, self: ^CubeImageBuffer) {
  if self == nil {
    return
  }
  for &v in self.face_views {
    vk.DestroyImageView(device, v, nil)
    v = 0
  }
  image_destroy(device, &self.base)
}

// Create image buffer with custom mip levels
malloc_image_buffer_with_mips :: proc(
  gctx: ^GPUContext,
  width, height: u32,
  format: vk.Format,
  tiling: vk.ImageTiling,
  usage: vk.ImageUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
  mip_levels: u32,
) -> (
  img_buffer: ImageBuffer,
  ret: vk.Result,
) {
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {width, height, 1},
    mipLevels     = mip_levels,
    arrayLayers   = 1,
    format        = format,
    tiling        = tiling,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
  }
  vk.CreateImage(gctx.device, &create_info, nil, &img_buffer.image) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(gctx.device, img_buffer.image, &mem_reqs)
  img_buffer.memory = allocate_vulkan_memory(
    gctx,
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindImageMemory(
    gctx.device,
    img_buffer.image,
    img_buffer.memory,
    0,
  ) or_return
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = format
  return img_buffer, .SUCCESS
}

// Create image view with mip levels
create_image_view_with_mips :: proc(
  device: vk.Device,
  image: vk.Image,
  format: vk.Format,
  aspect: vk.ImageAspectFlags,
  mip_levels: u32,
) -> (
  view: vk.ImageView,
  ret: vk.Result,
) {
  log.infof("Creating image view with %d mip levels", mip_levels)
  create_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = image,
    viewType = .D2,
    format = format,
    subresourceRange = {
      aspectMask = aspect,
      baseMipLevel = 0,
      levelCount = mip_levels,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  vk.CreateImageView(device, &create_info, nil, &view) or_return
  log.infof(
    "Image view created successfully with mip levels 0-%d",
    mip_levels - 1,
  )
  return view, .SUCCESS
}

// Generate mip maps for an image
generate_mipmaps :: proc(
  gctx: ^GPUContext,
  img: ImageBuffer,
  format: vk.Format,
  tex_width, tex_height: u32,
  mip_levels: u32,
) -> vk.Result {
  format_props: vk.FormatProperties
  vk.GetPhysicalDeviceFormatProperties(
    gctx.physical_device,
    format,
    &format_props,
  )
  if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
    log.errorf("Texture image format does not support linear blitting!")
    return .ERROR_UNKNOWN
  }
  cmd_buffer := begin_single_time_command(gctx) or_return
  defer end_single_time_command(gctx, &cmd_buffer)
  // First, transition all mip levels from UNDEFINED to TRANSFER_DST_OPTIMAL
  init_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    image = img.image,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    oldLayout = .UNDEFINED,
    newLayout = .TRANSFER_DST_OPTIMAL,
    srcAccessMask = {},
    dstAccessMask = {.TRANSFER_WRITE},
    subresourceRange = {
      aspectMask = {.COLOR},
      baseArrayLayer = 0,
      layerCount = 1,
      baseMipLevel = 0,
      levelCount = mip_levels,
    },
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TOP_OF_PIPE},
    {.TRANSFER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &init_barrier,
  )
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    image = img.image,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseArrayLayer = 0,
      layerCount = 1,
      levelCount = 1,
    },
  }
  mip_width := i32(tex_width)
  mip_height := i32(tex_height)
  for i in 1 ..< mip_levels {
    barrier.subresourceRange.baseMipLevel = i - 1
    barrier.oldLayout = .TRANSFER_DST_OPTIMAL
    barrier.newLayout = .TRANSFER_SRC_OPTIMAL
    barrier.srcAccessMask = {.TRANSFER_WRITE}
    barrier.dstAccessMask = {.TRANSFER_READ}
    vk.CmdPipelineBarrier(
      cmd_buffer,
      {.TRANSFER},
      {.TRANSFER},
      {},
      0,
      nil,
      0,
      nil,
      1,
      &barrier,
    )
    blit := vk.ImageBlit {
      srcOffsets = {{0, 0, 0}, {mip_width, mip_height, 1}},
      srcSubresource = {
        aspectMask = {.COLOR},
        mipLevel = i - 1,
        baseArrayLayer = 0,
        layerCount = 1,
      },
      dstOffsets = {
        {0, 0, 0},
        {max(mip_width / 2, 1), max(mip_height / 2, 1), 1},
      },
      dstSubresource = {
        aspectMask = {.COLOR},
        mipLevel = i,
        baseArrayLayer = 0,
        layerCount = 1,
      },
    }
    vk.CmdBlitImage(
      cmd_buffer,
      img.image,
      .TRANSFER_SRC_OPTIMAL,
      img.image,
      .TRANSFER_DST_OPTIMAL,
      1,
      &blit,
      .LINEAR,
    )
    barrier.oldLayout = .TRANSFER_SRC_OPTIMAL
    barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
    barrier.srcAccessMask = {.TRANSFER_READ}
    barrier.dstAccessMask = {.SHADER_READ}
    vk.CmdPipelineBarrier(
      cmd_buffer,
      {.TRANSFER},
      {.FRAGMENT_SHADER},
      {},
      0,
      nil,
      0,
      nil,
      1,
      &barrier,
    )
    mip_width = max(mip_width / 2, 1)
    mip_height = max(mip_height / 2, 1)
  }
  // Mip generation complete
  barrier.subresourceRange.baseMipLevel = mip_levels - 1
  barrier.oldLayout = .TRANSFER_DST_OPTIMAL
  barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
  barrier.srcAccessMask = {.TRANSFER_WRITE}
  barrier.dstAccessMask = {.SHADER_READ}
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TRANSFER},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  return .SUCCESS
}
