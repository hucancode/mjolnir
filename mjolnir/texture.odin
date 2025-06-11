package mjolnir

import "core:c"
import "core:log"
import "core:slice"
import "core:strings"

import stbi "vendor:stb/image"
import vk "vendor:vulkan"

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
  sampler_info := vk.SamplerCreateInfo {
    sType         = .SAMPLER_CREATE_INFO,
    magFilter     = .LINEAR,
    minFilter     = .LINEAR,
    addressModeU  = .CLAMP_TO_EDGE,
    addressModeV  = .CLAMP_TO_EDGE,
    addressModeW  = .CLAMP_TO_EDGE,
    maxAnisotropy = 1.0,
    borderColor   = .INT_OPAQUE_WHITE,
    compareOp     = .LESS,
    mipmapMode    = .LINEAR,
  }
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
