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

data_buffer_write :: proc(
  self: ^DataBuffer,
  data: rawptr,
  len: vk.DeviceSize,
) -> vk.Result {
  return data_buffer_write_at(self, data, 0, len)
}

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

// --- ImageBuffer ---

ImageBuffer :: struct {
  image:         vk.Image,
  memory:        vk.DeviceMemory,
  width, height: u32,
  format:        vk.Format,
  view:          vk.ImageView,
}

// Deinitializes an ImageBuffer.
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
  vkd := ctx.vkd
  buffer.size = size
  buffer = malloc_host_visible_buffer(ctx, size, usage) or_return
  vk.MapMemory(
    vkd,
    buffer.memory,
    0,
    buffer.size,
    {},
    &buffer.mapped,
  ) or_return
  fmt.printfln("Init host visible buffer, buffer mapped at %x", buffer.mapped)
  if data != nil {
    mem.copy(buffer.mapped, data, int(size))
  }
  ret = .SUCCESS
  return
}

// Creates a device-local buffer and uploads data using a staging buffer.
create_local_buffer :: proc(
  ctx: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer,
  ret: vk.Result,
) {
  buffer = malloc_local_buffer(ctx, size, usage | {.TRANSFER_DST}) or_return
  if data != nil {
    staging := create_host_visible_buffer(
      ctx,
      size,
      {.TRANSFER_SRC},
      data,
    ) or_return
    defer data_buffer_deinit(&staging, ctx)
    copy_buffer(ctx, &buffer, &staging) or_return
  }
  ret = .SUCCESS
  return
}

copy_buffer :: proc(ctx: ^VulkanContext, dst, src: ^DataBuffer) -> vk.Result {
  cmd_buffer := begin_single_time_command(ctx) or_return
  region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = 0,
    size      = src.size,
  }
  vk.CmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, &region)
  fmt.printfln(
    "Copying buffer %x mapped %x to %x",
    src.buffer,
    src.mapped,
    dst.buffer,
  )
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

  src_access_mask: vk.AccessFlags = {}
  dst_access_mask: vk.AccessFlags = {}
  src_stage: vk.PipelineStageFlags = {}
  dst_stage: vk.PipelineStageFlags = {}

  if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
    src_access_mask = {}
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
  staging := create_host_visible_buffer(
    ctx,
    size,
    {.TRANSFER_SRC},
    data,
  ) or_return
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
