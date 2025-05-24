package mjolnir

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"

import stbi "vendor:stb/image"
import vk "vendor:vulkan"

import "resource"

ImageData :: struct {
  pixels:           []u8,
  width:            int,
  height:           int,
  channels_in_file: int,
  actual_channels:  int,
}

image_data_deinit :: proc(img: ^ImageData) {
  if img.pixels != nil {
    // free(img.pixels)
    img.pixels = nil
  }
  img.width = 0
  img.height = 0
  img.channels_in_file = 0
  img.actual_channels = 0
}

Texture :: struct {
  image_data: ImageData,
  buffer:     ImageBuffer,
  sampler:    vk.Sampler,
  ctx: ^VulkanContext,
}

create_texture_from_data :: proc(
  engine: ^Engine,
  data: []u8,
) -> (
  handle: resource.Handle,
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&engine.textures)
  texture_init_from_data(texture, data) or_return
  texute_init(texture, &engine.ctx) or_return
  delete(texture.image_data.pixels)
  texture.image_data.pixels = nil
  fmt.printfln(
    "created texture %d x %d -> id %d",
    texture.image_data.width,
    texture.image_data.height,
    texture.buffer.image,
  )
  ret = .SUCCESS
  return
}

create_texture_from_pixels :: proc(
  engine: ^Engine,
  pixels: []u8,
  width: int,
  height: int,
  channel: int,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: resource.Handle,
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&engine.textures)
  texture.image_data.pixels = pixels
  texture.image_data.width = width
  texture.image_data.height = height
  texture.image_data.channels_in_file = channel
  texture.image_data.actual_channels = channel
  texute_init(texture, &engine.ctx, format) or_return
  texture.image_data.pixels = nil
  fmt.printfln(
    "created texture %d x %d -> id %d",
    texture.image_data.width,
    texture.image_data.height,
    texture.buffer.image,
  )
  ret = .SUCCESS
  return
}

texture_init_from_data :: proc(self: ^Texture, data: []u8) -> vk.Result {
  w, h, c_in_file: c.int
  actual_channels: c.int = 4
  pixels_ptr := stbi.load_from_memory(
    raw_data(data),
    c.int(len(data)),
    &w,
    &h,
    &c_in_file,
    actual_channels,
  )
  if pixels_ptr == nil {
    fmt.eprintf(
      "Failed to load texture from data: %s\n",
      stbi.failure_reason(),
    )
    return .ERROR_UNKNOWN
  }
  num_bytes := int(w * h * 4)
  self.image_data.pixels = make([]u8, num_bytes)
  mem.copy(raw_data(self.image_data.pixels), pixels_ptr, num_bytes)
  stbi.image_free(pixels_ptr)
  self.image_data.width = int(w)
  self.image_data.height = int(h)
  self.image_data.channels_in_file = int(c_in_file)
  self.image_data.actual_channels = int(actual_channels)
  fmt.printfln("loaded image %d x %d", w, h)
  return .SUCCESS
}

create_texture_from_path :: proc(
  engine: ^Engine,
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&engine.textures)
  texture_init_from_path(texture, path) or_return
  texute_init(texture, &engine.ctx) or_return
  delete(texture.image_data.pixels)
  texture.image_data.pixels = nil
  ret = .SUCCESS
  return
}

texture_init_from_path :: proc(self: ^Texture, path: string) -> vk.Result {
  path_cstr := strings.clone_to_cstring(path)
  // defer free(path_cstr)
  w, h, c_in_file: c.int
  actual_channels: c.int = 4
  pixels_ptr := stbi.load(path_cstr, &w, &h, &c_in_file, actual_channels)
  if pixels_ptr == nil {
    fmt.eprintf(
      "Failed to load texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    return .ERROR_UNKNOWN
  }
  num_bytes := int(w * h * 4)
  self.image_data.pixels = make([]u8, num_bytes)
  mem.copy(raw_data(self.image_data.pixels), pixels_ptr, num_bytes)
  stbi.image_free(pixels_ptr)
  self.image_data.width = int(w)
  self.image_data.height = int(h)
  self.image_data.channels_in_file = int(c_in_file)
  self.image_data.actual_channels = int(actual_channels)
  fmt.printfln("loaded texture %d x %d", w, h)
  return .SUCCESS
}

texute_init :: proc(
  self: ^Texture,
  ctx: ^VulkanContext,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> vk.Result {
  self.ctx = ctx
  if self.image_data.pixels == nil || ctx == nil {
    return .ERROR_INITIALIZATION_FAILED
  }
  self.buffer = create_image_buffer(
    ctx,
    raw_data(self.image_data.pixels),
    size_of(u8) * vk.DeviceSize(len(self.image_data.pixels)),
    format,
    u32(self.image_data.width),
    u32(self.image_data.height),
  ) or_return
  sampler_info := vk.SamplerCreateInfo {
    sType         = .SAMPLER_CREATE_INFO,
    magFilter     = .LINEAR,
    minFilter     = .LINEAR,
    addressModeU  = .CLAMP_TO_EDGE,
    addressModeV  = .CLAMP_TO_EDGE,
    addressModeW  = .CLAMP_TO_EDGE,
    maxAnisotropy = 1.0,
    borderColor   = .INT_OPAQUE_WHITE,
    compareOp     = .ALWAYS,
    mipmapMode    = .LINEAR,
  }
  vk.CreateSampler(ctx.vkd, &sampler_info, nil, &self.sampler) or_return
  return .SUCCESS
}

texture_deinit :: proc(self: ^Texture) {
  if self == nil {return}
  if self.ctx != nil && self.sampler != 0 {
    vk.DestroySampler(self.ctx.vkd, self.sampler, nil)
    self.sampler = 0
  }
  image_buffer_deinit(self.ctx.vkd, &self.buffer)
  image_data_deinit(&self.image_data)
}

DepthTexture :: struct {
  buffer:     ImageBuffer,
  sampler:    vk.Sampler,
  ctx: ^VulkanContext,
}

depth_texture_init :: proc(
  self: ^DepthTexture,
  ctx: ^VulkanContext,
  width: u32,
  height: u32,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT},
) -> vk.Result {
  self.ctx = ctx
  self.buffer = create_depth_image(ctx, width, height, usage) or_return
  sampler_info := vk.SamplerCreateInfo {
    sType         = .SAMPLER_CREATE_INFO,
    magFilter     = .LINEAR,
    minFilter     = .LINEAR,
    addressModeU  = .CLAMP_TO_EDGE,
    addressModeV  = .CLAMP_TO_EDGE,
    addressModeW  = .CLAMP_TO_EDGE,
    maxAnisotropy = 1.0,
    borderColor   = .INT_OPAQUE_WHITE,
    compareOp     = .ALWAYS,
    mipmapMode    = .LINEAR,
  }
  vk.CreateSampler(ctx.vkd, &sampler_info, nil, &self.sampler) or_return
  return .SUCCESS
}

depth_texture_deinit :: proc(self: ^DepthTexture) {
  if self == nil {return}
  if self.ctx != nil && self.sampler != 0 {
    vk.DestroySampler(self.ctx.vkd, self.sampler, nil)
    self.sampler = 0
  }
  image_buffer_deinit(self.ctx.vkd, &self.buffer)
}

create_depth_image :: proc(
  ctx: ^VulkanContext,
  width: u32,
  height: u32,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT},
) -> (
  img: ImageBuffer,
  ret: vk.Result,
) {
  depth_image_init(&img, ctx, width, height, usage) or_return
  ret = .SUCCESS
  return
}

// Internal helper to create depth image and view
depth_image_init :: proc(
  img_buffer: ^ImageBuffer,
  ctx: ^VulkanContext,
  width: u32,
  height: u32,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT},
) -> vk.Result {
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = .D32_SFLOAT

  vk_device := ctx.vkd

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
  vk.CreateImage(vk_device, &create_info, nil, &img_buffer.image) or_return

  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(vk_device, img_buffer.image, &mem_requirements)

  memory_type_index, found := find_memory_type_index(
    ctx.physical_device,
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
  vk.AllocateMemory(vk_device, &alloc_info, nil, &img_buffer.memory) or_return

  vk.BindImageMemory(vk_device, img_buffer.image, img_buffer.memory, 0)

  cmd_buffer := begin_single_time_command(ctx) or_return

  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = .UNDEFINED,
    newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = img_buffer.image,
    subresourceRange = {
      aspectMask     = {.DEPTH},
      baseMipLevel   = 0,
      levelCount     = 1,
      baseArrayLayer = 0,
      layerCount     = 1,
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
  end_single_time_command(ctx, &cmd_buffer) or_return
  img_buffer.view = create_image_view(
    ctx.vkd,
    img_buffer.image,
    img_buffer.format,
    {.DEPTH},
  ) or_return
  return .SUCCESS
}

CubeDepthTexture :: struct {
  buffer:     ImageBuffer,
  views:      [6]vk.ImageView, // One view per face for rendering
  view:       vk.ImageView,    // Single cube view for sampling
  sampler:    vk.Sampler,
  ctx:        ^VulkanContext,
  size:       u32,
}

cube_depth_texture_init :: proc(
  self: ^CubeDepthTexture,
  ctx: ^VulkanContext,
  size: u32,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> vk.Result {
  self.ctx = ctx
  self.size = size
  self.buffer.width = size
  self.buffer.height = size
  self.buffer.format = .D32_SFLOAT

  vk_device := ctx.vkd
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
  vk.CreateImage(vk_device, &create_info, nil, &self.buffer.image) or_return

  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(vk_device, self.buffer.image, &mem_requirements)

  memory_type_index, found := find_memory_type_index(
    ctx.physical_device,
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
  vk.AllocateMemory(vk_device, &alloc_info, nil, &self.buffer.memory) or_return
  vk.BindImageMemory(vk_device, self.buffer.image, self.buffer.memory, 0)

  // Create 6 image views (one per face)
  for i in 0..<6 {
    view_info := vk.ImageViewCreateInfo {
      sType = .IMAGE_VIEW_CREATE_INFO,
      image = self.buffer.image,
      viewType = .D2,
      format = .D32_SFLOAT,
      components = vk.ComponentMapping {
        r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY,
      },
      subresourceRange = vk.ImageSubresourceRange {
        aspectMask = {.DEPTH},
        baseMipLevel = 0,
        levelCount = 1,
        baseArrayLayer = u32(i),
        layerCount = 1,
      },
    }
    vk.CreateImageView(vk_device, &view_info, nil, &self.views[i]) or_return
  }
  // Create a single cube view for sampling
  cube_view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = self.buffer.image,
    viewType = .CUBE,
    format = .D32_SFLOAT,
    components = vk.ComponentMapping {
      r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY,
    },
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 6,
    },
  }
  vk.CreateImageView(vk_device, &cube_view_info, nil, &self.view) or_return

  // Create sampler
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
  vk.CreateSampler(vk_device, &sampler_info, nil, &self.sampler) or_return
  return .SUCCESS
}

cube_depth_texture_deinit :: proc(self: ^CubeDepthTexture) {
  if self == nil {return}
  if self.ctx != nil && self.sampler != 0 {
    vk.DestroySampler(self.ctx.vkd, self.sampler, nil)
    self.sampler = 0
  }
  vkd := self.ctx.vkd
  for i in 0..<6 {
    if self.views[i] != 0 {
      vk.DestroyImageView(vkd, self.views[i], nil)
      self.views[i] = 0
    }
  }
  if self.view != 0 {
    vk.DestroyImageView(vkd, self.view, nil)
    self.view = 0
  }
  image_buffer_deinit(vkd, &self.buffer)
}

// Load a floating-point HDR image from path (for environment maps)
create_hdr_texture_from_path :: proc(
  engine: ^Engine,
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&engine.textures)
  path_cstr := strings.clone_to_cstring(path)
  w, h, c_in_file: c.int
  float_pixels_ptr := stbi.loadf(path_cstr, &w, &h, &c_in_file, 3) // force RGB
  if float_pixels_ptr == nil {
    fmt.eprintf(
      "Failed to load HDR texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return
  }
  num_floats := int(w * h * 3)
  float_pixels := make([]f32, num_floats)
  mem.copy(raw_data(float_pixels), float_pixels_ptr, num_floats * size_of(f32))
  stbi.image_free(float_pixels_ptr)
  // Vulkan expects 4 channels, so expand to RGBA
  rgba_pixels := make([]f32, w * h * 4)
  for i in 0..<w*h {
    rgba_pixels[i*4+0] = float_pixels[i*3+0]
    rgba_pixels[i*4+1] = float_pixels[i*3+1]
    rgba_pixels[i*4+2] = float_pixels[i*3+2]
    rgba_pixels[i*4+3] = 1.0
  }
  texture.image_data.pixels = transmute([]u8)rgba_pixels
  texture.image_data.width = int(w)
  texture.image_data.height = int(h)
  texture.image_data.channels_in_file = 3
  texture.image_data.actual_channels = 4
  texute_init(texture, &engine.ctx, .R32G32B32A32_SFLOAT) or_return
  texture.image_data.pixels = nil
  fmt.printfln("created HDR texture %d x %d -> id %d", w, h, texture.buffer.image)
  ret = .SUCCESS
  return
}
