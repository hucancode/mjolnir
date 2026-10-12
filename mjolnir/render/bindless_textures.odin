package render

import cont "../containers"
import "gpu"
import "core:c"
import "core:log"
import "core:os"
import "core:sync"
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

// Create the samplers and the bindless set with its layout, and write the
// samplers and the pyramid counters into it. Call once at startup, after the
// scene buffers and before pipeline layouts are built. Paired with
// bindless_shutdown.
bindless_init :: proc(r: ^Manager) -> vk.Result {
  gctx := &r.gctx
  d := &r.scene
  d.bindless_layout = gpu.create_descriptor_layout(gctx, ..BINDLESS_BINDINGS[:]) or_return
  for &sampler, type in r.samplers {
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
  gpu.allocate_descriptor_set(gctx, &d.bindless_set, &d.bindless_layout) or_return
  for sampler, type in r.samplers {
    gpu.write_descriptor(gctx, d.bindless_set, BINDING_SAMPLERS, u32(type), .SAMPLER, vk.DescriptorImageInfo{sampler = sampler})
  }
  gpu.write_descriptor(gctx, d.bindless_set, BINDING_PYRAMID_COUNTERS, 0, .STORAGE_BUFFER, gpu.buffer_info(&r.pyramid_counters))
  return .SUCCESS
}

// Destroy the samplers and the set layout; the set goes with the descriptor
// pool.
bindless_shutdown :: proc(r: ^Manager) {
  for &sampler in r.samplers {
    vk.DestroySampler(r.gctx.device, sampler, nil)
    sampler = 0
  }
  vk.DestroyDescriptorSetLayout(r.gctx.device, r.scene.bindless_layout, nil)
  r.scene.bindless_layout = 0
}

// Pool retire callback: no frame in flight samples the image any more.
@(private = "file")
retire_image :: proc(r: ^Manager, index: u32) {
  img := &r.textures[index]
  if img.image != 0 do gpu.image_destroy(r.gctx.device, img)
}

// Reclaim retired texture slots and destroy their images. Call once per
// frame, after wait_frame.
@(private)
textures_tick :: proc(r: ^Manager) {
  for i in cont.slots_tick(&r.texture_slots) do retire_image(r, i)
}

// Destroy every texture and free the slots. The caller has waited for the GPU
// to go idle, so retired images go at once.
@(private)
textures_destroy :: proc(r: ^Manager) {
  for i in cont.slots_flush(&r.texture_slots) do retire_image(r, i)
  c: u32
  for i in cont.slots_next(&r.texture_slots, &c) do retire_image(r, i)
  cont.slots_destroy(&r.texture_slots)
  delete(r.textures)
  r.textures = nil
}

// The image of a live texture, nil for a stale or empty handle.
@(private)
texture_image :: proc(r: ^Manager, handle: TextureHandle) -> ^gpu.Image {
  return cont.slots_get(&r.texture_slots, r.textures, handle)
}

// Allocate a texture in the bindless array: 2D, or a cube when `cube` (the
// shaders' textureCube array aliases the same binding). `data` fills level 0
// and generates the remaining mip levels.
@(private)
allocate_texture :: proc(
  r: ^Manager,
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
  gctx := &r.gctx
  sync.recursive_mutex_lock(&r.mutex)
  defer sync.recursive_mutex_unlock(&r.mutex)
  // level 0 is copied in, the other levels blitted down from it
  usage := usage | ({.TRANSFER_DST, .TRANSFER_SRC} if data != nil else {})
  img := gpu.image_create(gctx, extent, format, usage, mip_levels, cube = cube, shared = shared, components = swizzle) or_return
  if data != nil {
    if ret = gpu.queue_image_write(gctx, &img, raw_data(data), len(data)); ret != .SUCCESS {
      gpu.image_destroy(gctx.device, &img)
      return
    }
  }
  h, ok := cont.slots_alloc(&r.texture_slots, TextureHandle)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  r.textures[h.index] = img
  gpu.write_descriptor(gctx, r.scene.bindless_set, BINDING_TEXTURES, h.index, .SAMPLED_IMAGE, vk.DescriptorImageInfo{imageView = img.view, imageLayout = .GENERAL})
  return h, .SUCCESS
}

// Free a texture. The handle is invalidated at once; its slot and image are
// released once no frame in flight samples them. teardown frees every
// texture.
destroy_texture :: proc(r: ^Manager, handle: TextureHandle) {
  sync.recursive_mutex_lock(&r.mutex)
  defer sync.recursive_mutex_unlock(&r.mutex)
  cont.slots_free(&r.texture_slots, handle)
}

// Bindless index shaders read for a texture slot: NO_TEXTURE when empty.
texture_index :: proc(h: $H) -> u32 {
  return h.index if h.generation != 0 else NO_TEXTURE
}

// Decode an encoded image (png, jpg, hdr, ...) held in memory into a bindless
// 2D texture. A float format decodes it as linear HDR.
create_texture_from_data :: proc(
  r: ^Manager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
  ret: vk.Result,
) {
  width, height, channels: c.int
  pixels: rawptr
  texel_size: c.int = 4
  if format == .R32G32B32A32_SFLOAT {
    pixels = stbi.loadf_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
    texel_size *= size_of(f32)
  } else {
    pixels = stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
  }
  if pixels == nil {
    log.errorf("Failed to decode texture: %s", stbi.failure_reason())
    return {}, .ERROR_UNKNOWN
  }
  defer stbi.image_free(pixels)
  extent := vk.Extent2D{u32(width), u32(height)}
  return allocate_texture(
    r,
    extent,
    format,
    {.SAMPLED},
    gpu.calculate_mip_levels(extent.width, extent.height) if generate_mips else 1,
    data = ([^]u8)(pixels)[:width * height * texel_size],
  )
}

// Load an image file (png, jpg, hdr, ...) into a bindless 2D texture.
create_texture_from_path :: proc(
  r: ^Manager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
  ret: vk.Result,
) {
  data, err := os.read_entire_file(path, context.allocator)
  if err != nil {
    log.errorf("Failed to read texture '%s': %v", path, err)
    return {}, .ERROR_UNKNOWN
  }
  defer delete(data)
  return create_texture_from_data(r, data, format, generate_mips)
}
