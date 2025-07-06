package mjolnir

import "core:log"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

DataBuffer :: struct($T: typeid) {
  buffer:       vk.Buffer,
  memory:       vk.DeviceMemory,
  mapped:       [^]T,
  element_size: int,
  bytes_count:  int,
}

malloc_data_buffer :: proc(
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
) -> (
  data_buf: DataBuffer(T),
  ret: vk.Result,
) {
  if .UNIFORM_BUFFER in usage && count > 1 {
    data_buf.element_size = align_up(
      size_of(T),
      int(g_device_properties.limits.minUniformBufferOffsetAlignment),
    )
  } else {
    data_buf.element_size = size_of(T)
  }
  data_buf.bytes_count = data_buf.element_size * count
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = vk.DeviceSize(data_buf.bytes_count),
    usage       = usage,
    sharingMode = .EXCLUSIVE,
  }
  vk.CreateBuffer(g_device, &create_info, nil, &data_buf.buffer) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(g_device, data_buf.buffer, &mem_reqs)
  data_buf.memory = allocate_vulkan_memory(mem_reqs, mem_properties) or_return
  vk.BindBufferMemory(g_device, data_buf.buffer, data_buf.memory, 0) or_return
  return data_buf, .SUCCESS
}

malloc_local_buffer :: proc(
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  DataBuffer(T),
  vk.Result,
) {
  return malloc_data_buffer(T, count, usage, {.DEVICE_LOCAL})
}

malloc_host_visible_buffer :: proc(
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
) -> (
  DataBuffer(T),
  vk.Result,
) {
  return malloc_data_buffer(T, count, usage, {.HOST_VISIBLE, .HOST_COHERENT})
}

align_up :: proc(value: int, alignment: int) -> int {
  return (value + alignment - 1) & ~(alignment - 1)
}

data_buffer_write :: proc {
  data_buffer_write_single,
  data_buffer_write_multi,
}

data_buffer_write_single :: proc(
  self: ^DataBuffer($T),
  data: ^T,
  index: int = 0,
) -> vk.Result {
  if self.mapped == nil {
    return .ERROR_UNKNOWN
  }
  offset := index * self.element_size
  if offset + self.element_size > self.bytes_count {
    return .ERROR_UNKNOWN
  }
  destination := mem.ptr_offset(cast([^]u8)self.mapped, offset)
  mem.copy(destination, data, size_of(T))
  return .SUCCESS
}

data_buffer_write_multi :: proc(
  self: ^DataBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  if self.mapped == nil {
    return .ERROR_UNKNOWN
  }
  offset := index * self.element_size
  if offset + (self.element_size) * len(data) > self.bytes_count {
    return .ERROR_UNKNOWN
  }
  destination := mem.ptr_offset(cast([^]u8)self.mapped, offset)
  mem.copy(destination, raw_data(data), slice.size(data))
  return .SUCCESS
}

data_buffer_get :: proc(self: ^DataBuffer($T), index: u32 = 0) -> ^T {
  return &self.mapped[index]
}

data_buffer_offset_of :: proc(self: ^DataBuffer($T), index: u32) -> u32 {
  return index * u32(self.element_size)
}

data_buffer_deinit :: proc(buffer: ^DataBuffer($T)) {
  if buffer.mapped != nil {
    vk.UnmapMemory(g_device, buffer.memory)
    buffer.mapped = nil
  }
  vk.DestroyBuffer(g_device, buffer.buffer, nil)
  buffer.buffer = 0
  vk.FreeMemory(g_device, buffer.memory, nil)
  buffer.memory = 0
  buffer.bytes_count = 0
  buffer.element_size = 0
}

create_host_visible_buffer :: proc(
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer(T),
  ret: vk.Result,
) {
  buffer = malloc_host_visible_buffer(T, count, usage) or_return
  vk.MapMemory(
    g_device,
    buffer.memory,
    0,
    vk.DeviceSize(buffer.bytes_count),
    {},
    auto_cast &buffer.mapped,
  ) or_return
  log.infof("Init host visible buffer, buffer mapped at %v", &buffer.mapped)
  if data != nil {
    mem.copy(buffer.mapped, data, buffer.bytes_count)
  }
  ret = .SUCCESS
  return
}

create_local_buffer :: proc(
  $T: typeid,
  count: int,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer(T),
  ret: vk.Result,
) {
  buffer = malloc_local_buffer(T, count, usage | {.TRANSFER_DST}) or_return
  defer log.info("done creating buffer")
  if data == nil {
    ret = .SUCCESS
    return
  }
  log.info("creating staging buffer with data ", data)
  staging := create_host_visible_buffer(
    T,
    count,
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer data_buffer_deinit(&staging)
  copy_buffer(buffer, staging) or_return
  ret = .SUCCESS
  return
}

copy_buffer :: proc(dst, src: DataBuffer($T)) -> vk.Result {
  cmd_buffer := begin_single_time_command() or_return
  region := vk.BufferCopy {
    size = vk.DeviceSize(src.bytes_count),
  }
  vk.CmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, &region)
  log.infof(
    "Copying buffer %x mapped %x to %x",
    src.buffer,
    src.mapped,
    dst.buffer,
  )
  return end_single_time_command(&cmd_buffer)
}

malloc_image_buffer :: proc(
  width: u32,
  height: u32,
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
  vk.CreateImage(g_device, &create_info, nil, &img_buffer.image) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(g_device, img_buffer.image, &mem_reqs)
  img_buffer.memory = allocate_vulkan_memory(
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindImageMemory(
    g_device,
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

image_buffer_deinit :: proc(self: ^ImageBuffer) {
  vk.DestroyImageView(g_device, self.view, nil)
  self.view = 0
  vk.DestroyImage(g_device, self.image, nil)
  self.image = 0
  vk.FreeMemory(g_device, self.memory, nil)
  self.memory = 0
  self.width = 0
  self.height = 0
  self.format = .UNDEFINED
}

create_image_view :: proc(
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
  res = vk.CreateImageView(g_device, &create_info, nil, &view)
  return
}

transition_image_layout :: proc(
  image: vk.Image,
  format: vk.Format,
  old_layout, new_layout: vk.ImageLayout,
) -> vk.Result {
  cmd_buffer := begin_single_time_command() or_return
  src_access_mask: vk.AccessFlags
  dst_access_mask: vk.AccessFlags
  src_stage: vk.PipelineStageFlags
  dst_stage: vk.PipelineStageFlags
  if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
    dst_access_mask = {.TRANSFER_WRITE}
    src_stage = {.TOP_OF_PIPE}
    dst_stage = {.TRANSFER}
  } else if old_layout == .TRANSFER_DST_OPTIMAL &&
     new_layout == .SHADER_READ_ONLY_OPTIMAL {
    src_access_mask = {.TRANSFER_WRITE}
    dst_access_mask = {.SHADER_READ}
    src_stage = {.TRANSFER}
    dst_stage = {.FRAGMENT_SHADER}
  } else {
    // Fallback: generic, but not optimal
    src_stage = {.TOP_OF_PIPE}
    dst_stage = {.TOP_OF_PIPE}
  }
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = new_layout,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = src_access_mask,
    dstAccessMask = dst_access_mask,
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  return end_single_time_command(&cmd_buffer)
}

copy_image :: proc(dst: ImageBuffer, src: DataBuffer(u8)) -> vk.Result {
  transition_image_layout(
    dst.image,
    dst.format,
    .UNDEFINED,
    .TRANSFER_DST_OPTIMAL,
  ) or_return
  cmd_buffer := begin_single_time_command() or_return
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
  end_single_time_command(&cmd_buffer) or_return
  transition_image_layout(
    dst.image,
    dst.format,
    .TRANSFER_DST_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
  ) or_return
  return .SUCCESS
}

// Copy image but leave in TRANSFER_DST_OPTIMAL for mip generation
copy_image_for_mips :: proc(dst: ImageBuffer, src: DataBuffer(u8)) -> vk.Result {
  transition_image_layout(
    dst.image,
    dst.format,
    .UNDEFINED,
    .TRANSFER_DST_OPTIMAL,
  ) or_return
  cmd_buffer := begin_single_time_command() or_return
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
  end_single_time_command(&cmd_buffer) or_return
  // Don't transition to SHADER_READ_ONLY - leave in TRANSFER_DST_OPTIMAL for mip generation
  return .SUCCESS
}

create_image_buffer :: proc(
  data: rawptr,
  size: vk.DeviceSize,
  format: vk.Format,
  width, height: u32,
) -> (
  img: ImageBuffer,
  ret: vk.Result,
) {
  staging := create_host_visible_buffer(
    u8,
    int(size),
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer data_buffer_deinit(&staging)
  img = malloc_image_buffer(
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  copy_image(img, staging) or_return
  aspect_mask := vk.ImageAspectFlags{.COLOR}
  img.view = create_image_view(img.image, format, aspect_mask) or_return
  ret = .SUCCESS
  return
}
depth_image_init :: proc(
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
  vk.CreateImage(g_device, &create_info, nil, &img_buffer.image) or_return
  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(g_device, img_buffer.image, &mem_requirements)
  memory_type_index, found := find_memory_type_index(
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
  vk.AllocateMemory(g_device, &alloc_info, nil, &img_buffer.memory) or_return
  vk.BindImageMemory(g_device, img_buffer.image, img_buffer.memory, 0)
  cmd_buffer := begin_single_time_command() or_return
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
  end_single_time_command(&cmd_buffer) or_return
  img_buffer.view = create_image_view(
    img_buffer.image,
    img_buffer.format,
    {.DEPTH},
  ) or_return
  return .SUCCESS
}

CubeImageBuffer :: struct {
  using buffer: ImageBuffer,
  face_views:   [6]vk.ImageView, // One view per face for rendering
}

cube_depth_texture_init :: proc(
  self: ^CubeImageBuffer,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> vk.Result {
  self.width = size
  self.height = size
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {size, size, 1},
    mipLevels     = 1,
    arrayLayers   = 6,
    format        = .D32_SFLOAT,
    tiling        = .OPTIMAL,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
    flags         = {.CUBE_COMPATIBLE},
  }
  vk.CreateImage(g_device, &create_info, nil, &self.image) or_return
  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(g_device, self.image, &mem_requirements)
  memory_type_index, found := find_memory_type_index(
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
  vk.AllocateMemory(g_device, &alloc_info, nil, &self.memory) or_return
  vk.BindImageMemory(g_device, self.image, self.memory, 0)
  // Create 6 image views (one per face)
  for i in 0 ..< 6 {
    view_info := vk.ImageViewCreateInfo {
      sType = .IMAGE_VIEW_CREATE_INFO,
      image = self.image,
      viewType = .D2,
      format = .D32_SFLOAT,
      components = {
        r = .IDENTITY,
        g = .IDENTITY,
        b = .IDENTITY,
        a = .IDENTITY,
      },
      subresourceRange = {
        aspectMask = {.DEPTH},
        baseMipLevel = 0,
        levelCount = 1,
        baseArrayLayer = u32(i),
        layerCount = 1,
      },
    }
    vk.CreateImageView(
      g_device,
      &view_info,
      nil,
      &self.face_views[i],
    ) or_return
  }
  cube_view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = self.image,
    viewType = .CUBE,
    format = .D32_SFLOAT,
    components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
    subresourceRange = {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 6,
    },
  }
  vk.CreateImageView(g_device, &cube_view_info, nil, &self.view) or_return
  return .SUCCESS
}

cube_depth_texture_deinit :: proc(self: ^CubeImageBuffer) {
  if self == nil {
    return
  }
  for &v in self.face_views {
    vk.DestroyImageView(g_device, v, nil)
    v = 0
  }
  vk.DestroyImageView(g_device, self.view, nil)
  self.view = 0
  image_buffer_deinit(&self.buffer)
}

prepare_image_for_render :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
  old_layout: vk.ImageLayout = .UNDEFINED,
) {
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = .COLOR_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
}

// Create image buffer with custom mip levels
malloc_image_buffer_with_mips :: proc(
  width: u32,
  height: u32,
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
  vk.CreateImage(g_device, &create_info, nil, &img_buffer.image) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(g_device, img_buffer.image, &mem_reqs)
  img_buffer.memory = allocate_vulkan_memory(
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindImageMemory(
    g_device,
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
  vk.CreateImageView(g_device, &create_info, nil, &view) or_return
  log.infof("Image view created successfully with mip levels 0-%d", mip_levels - 1)
  return view, .SUCCESS
}

// Generate mip maps for an image
generate_mipmaps :: proc(
  img: ImageBuffer,
  format: vk.Format,
  tex_width, tex_height: u32,
  mip_levels: u32,
) -> vk.Result {
  format_props: vk.FormatProperties
  vk.GetPhysicalDeviceFormatProperties(g_physical_device, format, &format_props)
  if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
    log.errorf("Texture image format does not support linear blitting!")
    return .ERROR_UNKNOWN
  }
  cmd_buffer := begin_single_time_command() or_return
  defer end_single_time_command(&cmd_buffer)
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
  for i in 1..<mip_levels {
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
      0, nil,
      0, nil,
      1, &barrier,
    )
    blit := vk.ImageBlit {
      srcOffsets = {
        {0, 0, 0},
        {mip_width, mip_height, 1},
      },
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
      img.image, .TRANSFER_SRC_OPTIMAL,
      img.image, .TRANSFER_DST_OPTIMAL,
      1, &blit,
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
      0, nil,
      0, nil,
      1, &barrier,
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
    0, nil,
    0, nil,
    1, &barrier,
  )
  return .SUCCESS
}

prepare_image_for_shader_read :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
  old_layout: vk.ImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
) {
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
    dstAccessMask = {.SHADER_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
}

prepare_image_for_present :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
) {
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.BOTTOM_OF_PIPE},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
}
