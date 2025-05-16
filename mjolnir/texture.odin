package mjolnir

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
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
  vk_ctx_ref: ^VulkanContext,
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
  texute_init(texture, &engine.vk_ctx) or_return
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
  texute_init(texture, &engine.vk_ctx, format) or_return
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
  texute_init(texture, &engine.vk_ctx) or_return
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
  vk_ctx: ^VulkanContext,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> vk.Result {
  self.vk_ctx_ref = vk_ctx
  if self.image_data.pixels == nil || vk_ctx == nil {
    return .ERROR_INITIALIZATION_FAILED
  }
  self.buffer = create_image_buffer(
    vk_ctx,
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
  vk.CreateSampler(vk_ctx.vkd, &sampler_info, nil, &self.sampler) or_return
  return .SUCCESS
}

texture_deinit :: proc(self: ^Texture) {
  if self == nil {return}
  if self.vk_ctx_ref != nil && self.sampler != 0 {
    vk.DestroySampler(self.vk_ctx_ref.vkd, self.sampler, nil)
    self.sampler = 0
  }
  image_buffer_init(self.vk_ctx_ref.vkd, &self.buffer)
  image_data_deinit(&self.image_data)
}

DepthTexture :: struct {
  buffer:     ImageBuffer,
  sampler:    vk.Sampler,
  vk_ctx_ref: ^VulkanContext,
}

depth_texture_init :: proc(
  self: ^DepthTexture,
  vk_ctx: ^VulkanContext,
  width: u32,
  height: u32,
) -> vk.Result {
  self.vk_ctx_ref = vk_ctx
  self.buffer = create_depth_image(vk_ctx, width, height) or_return
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
  vk.CreateSampler(vk_ctx.vkd, &sampler_info, nil, &self.sampler) or_return
  return .SUCCESS
}

depth_texture_deinit :: proc(self: ^DepthTexture) {
  if self == nil {return}
  if self.vk_ctx_ref != nil && self.sampler != 0 {
    vk.DestroySampler(self.vk_ctx_ref.vkd, self.sampler, nil)
    self.sampler = 0
  }
  image_buffer_init(self.vk_ctx_ref.vkd, &self.buffer)
}

create_depth_image :: proc(
  vk_ctx: ^VulkanContext,
  width: u32,
  height: u32,
) -> (
  img: ImageBuffer,
  ret: vk.Result,
) {
  depth_image_init(&img, vk_ctx, width, height) or_return
  ret = .SUCCESS
  return
}

// Internal helper to create depth image and view
depth_image_init :: proc(
  img_buffer: ^ImageBuffer,
  ctx: ^VulkanContext,
  width: u32,
  height: u32,
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
    usage         = {.DEPTH_STENCIL_ATTACHMENT},
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
      aspectMask     = {.DEPTH}, // Corrected enum value
      baseMipLevel   = 0,
      levelCount     = 1,
      baseArrayLayer = 0,
      layerCount     = 1,
    },
    srcAccessMask = {}, // No source access needed for UNDEFINED -> WRITE
    dstAccessMask = {
      .DEPTH_STENCIL_ATTACHMENT_READ,
      .DEPTH_STENCIL_ATTACHMENT_WRITE,
    }, // Corrected enum values
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    {.TOP_OF_PIPE}, // Corrected enum value
    {.EARLY_FRAGMENT_TESTS}, // Corrected enum value (or LATE_FRAGMENT_TESTS depending on usage)
    {}, // No dependency flags
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
