package render

import cont "../containers"
import "gpu"
import "core:c"
import "core:log"
import "core:strings"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

MAX_TEXTURES :: 1000
MAX_CUBE_TEXTURES :: 200

// Bindings of the bindless set.
@(private)
BINDING_TEXTURES :: 0 // [MAX_TEXTURES] 2D sampled images
@(private)
BINDING_SAMPLERS :: 1 // one sampler per SamplerType
@(private)
BINDING_CUBE_TEXTURES :: 2 // [MAX_CUBE_TEXTURES] cube sampled images
Texture2DHandle :: distinct cont.Handle
TextureCubeHandle :: distinct cont.Handle

// TextureManager manages textures with handle pools.
// Handle.index maps directly to descriptor array indices.
TextureManager :: struct {
  images_2d:               cont.Pool(gpu.Image),
  images_cube:             cont.Pool(gpu.Image),
  set_layout:     vk.DescriptorSetLayout,
  descriptor_set: vk.DescriptorSet,
  samplers:       [SamplerType]vk.Sampler,
}

// Initialize the texture manager: creates the samplers, the descriptor set and
// its layout. Must be called once at startup, before pipeline layouts are built.
texture_manager_init :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) -> vk.Result {
  self.set_layout = gpu.create_descriptor_array_layout(
    gctx,
    {.SAMPLED_IMAGE, MAX_TEXTURES, {.FRAGMENT}},
    {.SAMPLER, len(SamplerType), {.FRAGMENT}},
    {.SAMPLED_IMAGE, MAX_CUBE_TEXTURES, {.FRAGMENT}},
  ) or_return
  for &sampler, type in self.samplers {
    linear := type == .LINEAR_CLAMP || type == .LINEAR_REPEAT || type == .SHADOW_COMPARE
    repeat := type == .NEAREST_REPEAT || type == .LINEAR_REPEAT
    filter: vk.Filter = .LINEAR if linear else .NEAREST
    address: vk.SamplerAddressMode = .REPEAT if repeat else .CLAMP_TO_EDGE
    info := vk.SamplerCreateInfo {
      sType        = .SAMPLER_CREATE_INFO,
      magFilter    = filter,
      minFilter    = filter,
      addressModeU = address,
      addressModeV = address,
      addressModeW = address,
      mipmapMode   = .LINEAR,
      maxLod       = 1000,
    }
    if type == .SHADOW_COMPARE {
      // lit where the reference depth is at or in front of the stored one
      info.compareEnable = true
      info.compareOp = .LESS_OR_EQUAL
    }
    vk.CreateSampler(gctx.device, &info, nil, &sampler) or_return
  }
  gpu.allocate_descriptor_set(gctx, &self.descriptor_set, &self.set_layout) or_return
  for sampler, type in self.samplers {
    gpu.write_descriptor_array_element(gctx, self.descriptor_set, BINDING_SAMPLERS, u32(type), .SAMPLER, {sampler = sampler})
  }
  return .SUCCESS
}

// Level-lifetime texture pools. Paired with texture_manager_teardown.
texture_manager_setup :: proc(self: ^TextureManager) {
  // GPU images back descriptor slots the GPU samples for up to gpu.FRAMES_IN_FLIGHT
  // frames, so a freed slot/image must be retired, not reclaimed inline.
  cont.init(&self.images_2d, MAX_TEXTURES, gpu.FRAMES_IN_FLIGHT)
  cont.init(&self.images_cube, MAX_CUBE_TEXTURES, gpu.FRAMES_IN_FLIGHT)
}

@(private = "file")
retire_image :: proc(img: ^gpu.Image, user: rawptr) {
  if img.image != 0 do gpu.image_destroy((^gpu.GPUContext)(user).device, img)
}

// texture_manager_tick reclaims retired texture slots and destroys their vk
// images once no in-flight frame can still sample them. Call once per presented
// frame.
texture_manager_tick :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  cont.tick(&self.images_2d, gctx, retire_image)
  cont.tick(&self.images_cube, gctx, retire_image)
}

// Destroy every texture and free the pools. Paired with texture_manager_setup.
texture_manager_teardown :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  // Destroy any retired-but-not-yet-reclaimed images first; the caller has
  // already waited for the GPU to go idle, so grace no longer matters.
  cont.flush(&self.images_2d, gctx, retire_image)
  cont.flush(&self.images_cube, gctx, retire_image)
  it_2d := cont.iterator(&self.images_2d)
  for img in cont.next(&it_2d, Texture2DHandle) {
    if img.image != 0 do gpu.image_destroy(gctx.device, img)
  }
  it_cube := cont.iterator(&self.images_cube)
  for img in cont.next(&it_cube, TextureCubeHandle) {
    if img.image != 0 do gpu.image_destroy(gctx.device, img)
  }
  cont.destroy(&self.images_2d, proc(_: ^gpu.Image) {})
  cont.destroy(&self.images_cube, proc(_: ^gpu.Image) {})
  self.images_2d = {}
  self.images_cube = {}
}

// Destroy the samplers, descriptor set and layout. Paired with
// texture_manager_init.
texture_manager_shutdown :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  gpu.free_descriptor_sets(gctx, self.descriptor_set)
  for &sampler in self.samplers {
    vk.DestroySampler(gctx.device, sampler, nil)
    sampler = 0
  }
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self.set_layout = 0
}

// Allocate a 2D texture with the given parameters
allocate_texture_2d :: proc(
  self: ^TextureManager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  generate_mips: bool = false,
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  mips := gpu.calculate_mip_levels(extent.width, extent.height) if generate_mips else 1
  img := gpu.image_create(gctx, extent, format, usage, mips) or_return
  gpu_handle, slot, ok := cont.alloc(&self.images_2d, Texture2DHandle)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  slot^ = img
  // Update descriptor set
  write_texture_descriptor(gctx, self.descriptor_set, BINDING_TEXTURES, gpu_handle.index, img.view)
  return gpu_handle, .SUCCESS
}

// Allocate a 2D texture with initial data
allocate_texture_2d_with_data :: proc(
  tm: ^TextureManager,
  gctx: ^gpu.GPUContext,
  pixel_data: rawptr,
  data_size: vk.DeviceSize,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  generate_mips: bool = false,
  // channel remapping applied when sampling; identity by default
  swizzle: vk.ComponentMapping = {},
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  mips := gpu.calculate_mip_levels(extent.width, extent.height) if generate_mips else 1
  img := gpu.image_create_with_data(
    gctx,
    extent,
    format,
    usage,
    pixel_data,
    data_size,
    mips,
  ) or_return
  if swizzle != {} {
    vk.DestroyImageView(gctx.device, img.view, nil)
    img.view, ret = gpu.image_create_view(gctx.device, &img, .D2, mip_count = mips, components = swizzle)
    if ret != .SUCCESS {
      img.view = 0
      gpu.image_destroy(gctx.device, &img)
      return
    }
  }
  gpu_handle, slot, ok := cont.alloc(&tm.images_2d, Texture2DHandle)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  slot^ = img
  // Update descriptor set
  write_texture_descriptor(gctx, tm.descriptor_set, BINDING_TEXTURES, gpu_handle.index, img.view)
  return gpu_handle, .SUCCESS
}

// Free a 2D texture. The handle is invalidated immediately, but the slot and the
// underlying vk image are retired and destroyed by texture_manager_tick once no
// in-flight frame can still sample them.
free_texture_2d :: proc(tm: ^TextureManager, gctx: ^gpu.GPUContext, handle: $H) {
  gpu_handle := transmute(Texture2DHandle)handle
  cont.free_deferred(&tm.images_2d, gpu_handle)
}

// Get a pointer to a 2D texture
get_texture_2d :: proc(tm: ^TextureManager, handle: $H) -> ^gpu.Image {
  gpu_handle := transmute(Texture2DHandle)handle
  img, _ := cont.get(tm.images_2d, gpu_handle)
  return img
}

// Allocate a cube texture: a depth cube for point-light shadows or a color
// cube (with STORAGE usage and mips) for IBL precompute outputs.
allocate_texture_cube :: proc(
  tm: ^TextureManager,
  gctx: ^gpu.GPUContext,
  size: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  mip_levels: u32 = 1,
) -> (
  handle: TextureCubeHandle,
  ret: vk.Result,
) {
  img := gpu.image_create(gctx, {size, size}, format, usage, mip_levels, cube = true) or_return
  h, slot, ok := cont.alloc(&tm.images_cube, TextureCubeHandle)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  slot^ = img
  write_texture_descriptor(gctx, tm.descriptor_set, BINDING_CUBE_TEXTURES, h.index, img.view)
  return h, .SUCCESS
}

// Free a cube texture. Retired and destroyed by texture_manager_tick — see
// free_texture_2d.
free_texture_cube :: proc(tm: ^TextureManager, gctx: ^gpu.GPUContext, handle: $H) {
  gpu_handle := transmute(TextureCubeHandle)handle
  cont.free_deferred(&tm.images_cube, gpu_handle)
}

// Get a pointer to a cube texture
get_texture_cube :: proc(tm: ^TextureManager, handle: $H) -> ^gpu.Image {
  gpu_handle := transmute(TextureCubeHandle)handle
  img, _ := cont.get(tm.images_cube, gpu_handle)
  return img
}

@(private)
write_texture_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  set: vk.DescriptorSet,
  binding, index: u32,
  view: vk.ImageView,
) {
  gpu.write_descriptor_array_element(gctx, set, binding, index, .SAMPLED_IMAGE, {imageView = view, imageLayout = .GENERAL})
}

create_texture_2d_from_data :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  width, height, channels: c.int
  pixels := stbi.load_from_memory(
    raw_data(data),
    c.int(len(data)),
    &width,
    &height,
    &channels,
    4,
  )
  if pixels == nil {
    log.errorf("Failed to decode texture data: %s", stbi.failure_reason())
    return {}, .ERROR_UNKNOWN
  }
  defer stbi.image_free(pixels)
  pixel_size := vk.DeviceSize(width * height * 4)
  return allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    pixels,
    pixel_size,
    vk.Extent2D {u32(width), u32(height)},
    format,
    {.SAMPLED},
    generate_mips,
  )
}

create_texture_2d_from_path :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  path_cstr := strings.clone_to_cstring(path)
  defer delete(path_cstr)
  width, height, channels: c.int
  pixel_data: rawptr
  data_size: vk.DeviceSize
  // a float format decodes the file as linear HDR
  if format == .R32G32B32A32_SFLOAT {
    pixels := stbi.loadf(path_cstr, &width, &height, &channels, 4)
    if pixels == nil {
      log.errorf(
        "Failed to load HDR texture '%s': %s",
        path,
        stbi.failure_reason(),
      )
      return {}, .ERROR_UNKNOWN
    }
    pixel_data = pixels
    data_size = vk.DeviceSize(width * height * 4 * size_of(f32))
  } else {
    pixels := stbi.load(path_cstr, &width, &height, &channels, 4)
    if pixels == nil {
      log.errorf(
        "Failed to load texture '%s': %s",
        path,
        stbi.failure_reason(),
      )
      return {}, .ERROR_UNKNOWN
    }
    pixel_data = pixels
    data_size = vk.DeviceSize(width * height * 4)
  }
  defer stbi.image_free(pixel_data)
  return allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    pixel_data,
    data_size,
    vk.Extent2D {u32(width), u32(height)},
    format,
    usage,
    generate_mips,
  )
}
