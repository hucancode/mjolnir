package mjolnir

import "core:fmt"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"

// --- DataBuffer ---

DataBuffer :: struct {
  buffer: vk.Buffer,
  memory: vk.DeviceMemory,
  mapped: rawptr,
  size:   vk.DeviceSize,
}

// writeAt equivalent: writes data to the buffer at a specific offset.
// Returns true on success, false on failure (e.g., not mapped, out of bounds).
data_buffer_write_at :: proc(
  self: ^DataBuffer,
  data: rawptr,
  offset: vk.DeviceSize,
  len: vk.DeviceSize,
) -> vk.Result {
  if self.mapped == nil {
    return .ERROR_UNKNOWN
  }
  if offset + len > self.size {
    return .ERROR_UNKNOWN
  }
  destination_ptr := mem.ptr_offset(cast([^]u8)self.mapped, offset)
  mem.copy(destination_ptr, data, int(len))
  return .SUCCESS
}

// write equivalent: writes data to the buffer starting from offset 0.
// Returns true on success, false on failure.
data_buffer_write :: proc(
  self: ^DataBuffer,
  data: rawptr,
  len: vk.DeviceSize,
) -> vk.Result {
  return data_buffer_write_at(self, data, 0, len)
}

// Deinitializes a DataBuffer.
// Requires the Vulkan device (vkd) for destruction calls.
// Takes ^VulkanContext to access vkd and physical_device for find_memory_type_index.
data_buffer_deinit :: proc(buffer: ^DataBuffer, ctx: ^VulkanContext) {
  if buffer == nil || ctx == nil {
    return
  }
  vkd := ctx.vkd
  if buffer.mapped != nil {
    vk.UnmapMemory(vkd, buffer.memory)
    buffer.mapped = nil
  }
  if buffer.buffer != 0 {
    vk.DestroyBuffer(vkd, buffer.buffer, nil)
    buffer.buffer = 0
  }
  if buffer.memory != 0 {
    vk.FreeMemory(vkd, buffer.memory, nil)
    buffer.memory = 0
  }
  buffer.size = 0
}

// Initializes a host-visible buffer, allocates memory, binds it, maps it, and optionally copies data.
// Takes ^VulkanContext to access vkd and physical_device for find_memory_type_index.
data_buffer_init_host_visible :: proc(
  buffer: ^DataBuffer,
  ctx: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  data_to_push: rawptr = nil, // Optional initial data
) -> vk.Result {
  vkd := ctx.vkd
  buffer.size = size
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = size,
    usage       = usage,
    sharingMode = .EXCLUSIVE,
  }
  vk.CreateBuffer(vkd, &create_info, nil, &buffer.buffer) or_return
  mem_requirements: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(vkd, buffer.buffer, &mem_requirements)
  // find_memory_type_index is expected to be in the same package or imported.
  // Assuming it's in the 'device' package (e.g. from context.odin)
  mem_type_idx, found := find_memory_type_index(
    ctx.physical_device,
    mem_requirements.memoryTypeBits,
    {.HOST_VISIBLE, .HOST_COHERENT},
  )
  if !found {
    fmt.printfln("init_host_visible_buffer: Failed to find suitable memory type.")
    return .ERROR_UNKNOWN
  }

  alloc_info := vk.MemoryAllocateInfo {
    sType           = .MEMORY_ALLOCATE_INFO,
    allocationSize  = mem_requirements.size,
    memoryTypeIndex = mem_type_idx,
  }
  vk.AllocateMemory(vkd, &alloc_info, nil, &buffer.memory) or_return
  vk.BindBufferMemory(vkd, buffer.buffer, buffer.memory, 0) or_return
  vk.MapMemory(
    vkd,
    buffer.memory,
    0,
    buffer.size,
    {},
    &buffer.mapped,
  ) or_return
  fmt.printfln("Init host visible buffer, buffer mapped at %x", buffer.mapped)

  // If data_to_push is provided, copy it to the mapped buffer
  if data_to_push != nil {
    mem.copy(buffer.mapped, data_to_push, int(size))
  }
  return .SUCCESS
}


// --- ImageBuffer ---

ImageBuffer :: struct {
  image:  vk.Image,
  memory: vk.DeviceMemory,
  width, height: u32,
  format: vk.Format,
  view:   vk.ImageView,
}

// Deinitializes an ImageBuffer.
// Requires the Vulkan device (vkd) for destruction calls.
image_buffer_init :: proc(vkd: vk.Device, self: ^ImageBuffer) {
  if self.view != 0 {
    vk.DestroyImageView(vkd, self.view, nil)
    self.view = 0
  }
  if self.image != 0 {
    vk.DestroyImage(vkd, self.image, nil)
    self.image = 0
  }
  if self.memory != 0 {
    vk.FreeMemory(vkd, self.memory, nil)
    self.memory = 0
  }
  self.width = 0
  self.height = 0
  self.format = .UNDEFINED
}

// --- ImageView Creation ---

// Creates an ImageView.
// Requires the Vulkan device (vkd).
create_image_view :: proc(
  vkd: vk.Device,
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
    components = vk.ComponentMapping {
      r = .IDENTITY,
      g = .IDENTITY,
      b = .IDENTITY,
      a = .IDENTITY,
    },
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = aspect_mask,
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  res = vk.CreateImageView(vkd, &create_info, nil, &view)
  return
}

// Creates a host-visible buffer and writes initial data if provided.
create_host_visible_buffer :: proc(
  ctx: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer,
  ret: vk.Result,
) {
  data_buffer_init_host_visible(
    &buffer,
    ctx,
    size,
    usage,
    data,
  ) or_return
  ret = .SUCCESS
  return
}

// Creates a device-local buffer and uploads data using a staging buffer.
create_local_buffer :: proc(
  ctx: ^VulkanContext,
  data: rawptr,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
) -> (
  buffer: DataBuffer,
  ret: vk.Result,
) {
  staging := create_host_visible_buffer(ctx, size, {.TRANSFER_SRC}, data) or_return
  defer data_buffer_deinit(&staging, ctx)
  buffer = malloc_local_buffer(
    ctx,
    size,
    usage | {.TRANSFER_DST},
  ) or_return
  copy_buffer(ctx, &buffer, &staging) or_return
  ret = .SUCCESS
  return
}

// Copies data from src DataBuffer to dst DataBuffer using a single-use command buffer.
copy_buffer :: proc(
  ctx: ^VulkanContext,
  dst, src: ^DataBuffer,
) -> vk.Result {
  cmd_buffer := begin_single_time_command(ctx) or_return
  region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = 0,
    size      = src.size,
  }
  vk.CmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, &region)
  fmt.printfln("Copying buffer %x mapped %x to %x", src.buffer, src.mapped, dst.buffer)
  return end_single_time_command(ctx, &cmd_buffer)
}

// Transitions an image layout using a pipeline barrier.
transition_image_layout :: proc(
  ctx: ^VulkanContext,
  image: vk.Image,
  format: vk.Format,
  old_layout, new_layout: vk.ImageLayout,
) -> vk.Result {
  cmd_buffer := begin_single_time_command(ctx) or_return
  barrier := vk.ImageMemoryBarrier {
    oldLayout = old_layout,
    newLayout = new_layout,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = vk.ImageSubresourceRange {
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
  return end_single_time_command(ctx, &cmd_buffer)
}

// Copies data from a DataBuffer to an ImageBuffer (buffer to image copy).
copy_image :: proc(
  ctx: ^VulkanContext,
  dst: ^ImageBuffer,
  src: ^DataBuffer,
) -> vk.Result {
  transition_image_layout(
    ctx,
    dst.image,
    dst.format,
    .UNDEFINED,
    .TRANSFER_DST_OPTIMAL,
  ) or_return
  cmd_buffer := begin_single_time_command(ctx) or_return
  region := vk.BufferImageCopy {
    bufferOffset = 0,
    bufferRowLength = 0,
    bufferImageHeight = 0,
    imageSubresource = vk.ImageSubresourceLayers {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    imageOffset = vk.Offset3D{0, 0, 0},
    imageExtent = vk.Extent3D{dst.width, dst.height, 1},
  }
  vk.CmdCopyBufferToImage(
    cmd_buffer,
    src.buffer,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )
  end_single_time_command(ctx, &cmd_buffer) or_return
  transition_image_layout(
    ctx,
    dst.image,
    dst.format,
    .TRANSFER_DST_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
  ) or_return
  return .SUCCESS
}

// Creates an image buffer and uploads data using a staging buffer.
create_image_buffer :: proc(
  ctx: ^VulkanContext,
  data: rawptr,
  size: vk.DeviceSize,
  format: vk.Format,
  width, height: u32,
) -> (
  img: ImageBuffer,
  ret: vk.Result,
) {
  staging := create_host_visible_buffer(ctx, size, {.TRANSFER_SRC}, data) or_return
  defer data_buffer_deinit(&staging, ctx)
  img = malloc_image_buffer(
    ctx,
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  copy_image(ctx, &img, &staging) or_return
  aspect_mask := vk.ImageAspectFlags{.COLOR}
  img.view = create_image_view(
    ctx.vkd,
    img.image,
    format,
    aspect_mask,
  ) or_return
  ret = .SUCCESS
  return
}
