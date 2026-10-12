package render

import cont "../containers"
import "gpu"
import "core:c"
import "core:log"
import "core:strings"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

MAX_TEXTURES :: 1000
@(private)
MAX_STORAGE_IMAGES :: PRECOMPUTE_STORAGE_BASE + PRECOMPUTE_DISPATCHES

// Bindings of the bindless set (set 1). Shaders repeat these numbers as
// literals.
@(private)
BINDING_TEXTURES :: 0 // [MAX_TEXTURES] sampled images, 2D and cube
@(private)
BINDING_SAMPLERS :: 1 // one sampler per SamplerType
@(private)
BINDING_STORAGE_IMAGES :: 2 // [MAX_STORAGE_IMAGES] depth pyramid mips, IBL precompute targets
@(private)
BINDING_DRAW_LISTS :: 3 // [MAX_DRAW_LIST_SLOTS] indirect draw list buffers
@(private)
BINDING_PYRAMID_COUNTERS :: 4 // one u32 per depth pyramid
@(private)
BINDLESS_BINDINGS := [?]gpu.DescriptorBinding {
  BINDING_TEXTURES         = {.SAMPLED_IMAGE, MAX_TEXTURES, SCENE_STAGES},
  BINDING_SAMPLERS         = {.SAMPLER, len(SamplerType), SCENE_STAGES},
  BINDING_STORAGE_IMAGES   = {.STORAGE_IMAGE, MAX_STORAGE_IMAGES, {.COMPUTE}},
  BINDING_DRAW_LISTS       = {.STORAGE_BUFFER, MAX_DRAW_LIST_SLOTS, {.COMPUTE}},
  BINDING_PYRAMID_COUNTERS = {.STORAGE_BUFFER, 1, {.COMPUTE}},
}
TextureHandle :: distinct cont.Handle

// The bindless samplers; shaders index them with these values as literals.
SamplerType :: enum u32 {
  NEAREST_CLAMP  = 0,
  LINEAR_CLAMP   = 1,
  NEAREST_REPEAT = 2,
  LINEAR_REPEAT  = 3,
  // bilinear depth comparison (2x2 PCF) for shadow maps
  SHADOW_COMPARE = 4,
  // bilinear footprint reduced with MAX, for depth pyramids
  MAX_REDUCE     = 5,
}

// TextureManager manages textures with handle pools.
// Handle.index maps directly to descriptor array indices.
TextureManager :: struct {
  images:         cont.Pool(gpu.Image),
  set_layout:     vk.DescriptorSetLayout,
  descriptor_set: vk.DescriptorSet,
  samplers:       [SamplerType]vk.Sampler,
}

@(private = "file")
SAMPLERS := [SamplerType]struct {
  filter:    vk.Filter,
  address:   vk.SamplerAddressMode,
  mipmap:    vk.SamplerMipmapMode,
  reduction: vk.SamplerReductionMode,
  compare:   bool,
} {
  .NEAREST_CLAMP  = {.NEAREST, .CLAMP_TO_EDGE, .LINEAR, .WEIGHTED_AVERAGE, false},
  .LINEAR_CLAMP   = {.LINEAR, .CLAMP_TO_EDGE, .LINEAR, .WEIGHTED_AVERAGE, false},
  .NEAREST_REPEAT = {.NEAREST, .REPEAT, .LINEAR, .WEIGHTED_AVERAGE, false},
  .LINEAR_REPEAT  = {.LINEAR, .REPEAT, .LINEAR, .WEIGHTED_AVERAGE, false},
  .SHADOW_COMPARE = {.LINEAR, .CLAMP_TO_EDGE, .LINEAR, .WEIGHTED_AVERAGE, true},
  .MAX_REDUCE     = {.LINEAR, .CLAMP_TO_EDGE, .NEAREST, .MAX, false},
}

// Initialize the texture manager: creates the samplers, the descriptor set and
// its layout. Must be called once at startup, before pipeline layouts are built.
texture_manager_init :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) -> vk.Result {
  self.set_layout = gpu.create_descriptor_layout(gctx, ..BINDLESS_BINDINGS[:]) or_return
  for &sampler, type in self.samplers {
    desc := SAMPLERS[type]
    reduction := vk.SamplerReductionModeCreateInfo {
      sType         = .SAMPLER_REDUCTION_MODE_CREATE_INFO,
      reductionMode = desc.reduction,
    }
    info := vk.SamplerCreateInfo {
      sType         = .SAMPLER_CREATE_INFO,
      pNext         = &reduction,
      magFilter     = desc.filter,
      minFilter     = desc.filter,
      addressModeU  = desc.address,
      addressModeV  = desc.address,
      addressModeW  = desc.address,
      mipmapMode    = desc.mipmap,
      maxLod        = vk.LOD_CLAMP_NONE,
      compareEnable = b32(desc.compare),
      // lit where the reference depth is at or in front of the stored one
      compareOp     = .LESS_OR_EQUAL,
    }
    vk.CreateSampler(gctx.device, &info, nil, &sampler) or_return
  }
  gpu.allocate_descriptor_set(gctx, &self.descriptor_set, &self.set_layout) or_return
  for sampler, type in self.samplers {
    gpu.write_descriptor(gctx, self.descriptor_set, BINDING_SAMPLERS, u32(type), .SAMPLER, vk.DescriptorImageInfo{sampler = sampler})
  }
  return .SUCCESS
}

// Level-lifetime texture pools. Paired with texture_manager_teardown.
texture_manager_setup :: proc(self: ^TextureManager) {
  // GPU images back descriptor slots that submitted frames still sample, so
  // a freed slot/image must be retired, not reclaimed inline.
  cont.init(&self.images, MAX_TEXTURES, gpu.RETIRE_GRACE)
}

@(private = "file")
retire_image :: proc(img: ^gpu.Image, user: rawptr) {
  if img.image != 0 do gpu.image_destroy((^gpu.GPUContext)(user).device, img)
}

// texture_manager_tick reclaims retired texture slots and destroys their vk
// images once no in-flight frame can still sample them. Call once per presented
// frame.
texture_manager_tick :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  cont.tick(&self.images, gctx, retire_image)
}

// Destroy every texture and free the pools. Paired with texture_manager_setup.
texture_manager_teardown :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  // Destroy any retired-but-not-yet-reclaimed images first; the caller has
  // already waited for the GPU to go idle, so grace no longer matters.
  cont.flush(&self.images, gctx, retire_image)
  it := cont.iterator(&self.images)
  for img in cont.next(&it, TextureHandle) {
    if img.image != 0 do gpu.image_destroy(gctx.device, img)
  }
  cont.destroy(&self.images, proc(_: ^gpu.Image) {})
  self.images = {}
}

// Destroy the samplers and the set layout; the set goes with the descriptor
// pool. Paired with texture_manager_init.
texture_manager_shutdown :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  for &sampler in self.samplers {
    vk.DestroySampler(gctx.device, sampler, nil)
    sampler = 0
  }
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self.set_layout = 0
}

// Allocate a texture in the bindless array: 2D, or a cube when `cube` (the
// shaders' textureCube array aliases the same binding). `data` fills level 0
// and generates the remaining mip levels.
allocate_texture :: proc(
  self: ^TextureManager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  mip_levels: u32 = 1,
  cube := false,
  data: []u8 = nil,
  // channel remapping applied when sampling; identity by default
  swizzle: vk.ComponentMapping = {},
  shared := false, // also accessed by the async compute queue
) -> (
  handle: TextureHandle,
  ret: vk.Result,
) {
  img: gpu.Image
  if data != nil {
    img = gpu.image_create_with_data(gctx, extent, format, usage, raw_data(data), vk.DeviceSize(len(data)), mip_levels) or_return
  } else {
    img = gpu.image_create(gctx, extent, format, usage, mip_levels, cube = cube, shared = shared) or_return
  }
  if swizzle != {} {
    vk.DestroyImageView(gctx.device, img.view, nil)
    img.view, ret = gpu.image_create_view(gctx.device, &img, .D2, mip_count = mip_levels, components = swizzle)
    if ret != .SUCCESS {
      img.view = 0
      gpu.image_destroy(gctx.device, &img)
      return
    }
  }
  h, slot, ok := cont.alloc(&self.images, TextureHandle)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  slot^ = img
  gpu.write_descriptor(gctx, self.descriptor_set, BINDING_TEXTURES, h.index, .SAMPLED_IMAGE, vk.DescriptorImageInfo{imageView = img.view, imageLayout = .GENERAL})
  return h, .SUCCESS
}

// Free a texture. The handle is invalidated immediately, but the slot and the
// underlying vk image are retired and destroyed by texture_manager_tick once no
// in-flight frame can still sample them.
free_texture :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext, handle: TextureHandle) {
  cont.free_deferred(&self.images, handle)
}

get_texture :: proc(self: ^TextureManager, handle: TextureHandle) -> ^gpu.Image {
  img, _ := cont.get(self.images, handle)
  return img
}

// Bindless index shaders read for a texture slot: NO_TEXTURE when empty.
texture_index :: proc(h: $H) -> u32 {
  return h.index if h.generation != 0 else NO_TEXTURE
}

create_texture_2d_from_data :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
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
  extent := vk.Extent2D{u32(width), u32(height)}
  return allocate_texture(
    texture_manager,
    gctx,
    extent,
    format,
    {.SAMPLED},
    gpu.calculate_mip_levels(extent.width, extent.height) if generate_mips else 1,
    data = ([^]u8)(pixels)[:pixel_size],
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
  handle: TextureHandle,
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
  extent := vk.Extent2D{u32(width), u32(height)}
  return allocate_texture(
    texture_manager,
    gctx,
    extent,
    format,
    usage,
    gpu.calculate_mip_levels(extent.width, extent.height) if generate_mips else 1,
    data = ([^]u8)(pixel_data)[:data_size],
  )
}
