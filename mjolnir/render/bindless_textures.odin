package render

import cont "../containers"
import "gpu"
import "core:c"
import "core:log"
import "core:os"
import "core:sync"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

@(private)
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

// The bindless samplers; shaders index them with these values as literals.
SamplerType :: enum u32 {
  NEAREST_CLAMP  = 0,
  LINEAR_CLAMP   = 1,
  NEAREST_REPEAT = 2,
  LINEAR_REPEAT  = 3,
  // bilinear depth comparison (2x2 PCF) for shadow maps
  SHADOW_COMPARE = 4,
}

@(private = "file")
SAMPLERS := [SamplerType]struct {
  filter:    vk.Filter,
  address:   vk.SamplerAddressMode,
  mipmap:    vk.SamplerMipmapMode,
  compare:   bool,
} {
  .NEAREST_CLAMP  = {.NEAREST, .CLAMP_TO_EDGE, .LINEAR, false},
  .LINEAR_CLAMP   = {.LINEAR, .CLAMP_TO_EDGE, .LINEAR, false},
  .NEAREST_REPEAT = {.NEAREST, .REPEAT, .LINEAR, false},
  .LINEAR_REPEAT  = {.LINEAR, .REPEAT, .LINEAR, false},
  .SHADOW_COMPARE = {.LINEAR, .CLAMP_TO_EDGE, .LINEAR, true},
}

// After the scene buffers, before pipeline layouts are built.
@(private)
bindless_init :: proc(r: ^Renderer) -> vk.Result {
  gctx := &r.gctx
  d := &r.scene
  d.bindless_layout = gpu.create_descriptor_layout(gctx, ..BINDLESS_BINDINGS[:]) or_return
  for &sampler, type in r.samplers {
    desc := SAMPLERS[type]
    info := vk.SamplerCreateInfo {
      sType         = .SAMPLER_CREATE_INFO,
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

@(private)
bindless_shutdown :: proc(r: ^Renderer) {
  for &sampler in r.samplers {
    vk.DestroySampler(r.gctx.device, sampler, nil)
    sampler = 0
  }
  vk.DestroyDescriptorSetLayout(r.gctx.device, r.scene.bindless_layout, nil)
  r.scene.bindless_layout = 0
}

@(private)
texture_image :: proc(r: ^Renderer, handle: TextureHandle) -> ^gpu.Image {
  if !cont.slots_live(&r.texture_slots, u32(handle)) do return nil
  return &r.textures[handle]
}

// A cube aliases the same binding as the shaders' textureCube array. `data` fills level 0; the other levels are blitted down.
@(private)
allocate_texture :: proc(
  r: ^Renderer,
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
  guard(r)
  usage := usage | ({.TRANSFER_DST, .TRANSFER_SRC} if data != nil else {})
  img := gpu.image_create(gctx, extent, format, usage, mip_levels, cube = cube, shared = shared, components = swizzle) or_return
  if data != nil {
    if ret = gpu.queue_image_write(gctx, &img, raw_data(data), len(data)); ret != .SUCCESS {
      gpu.image_destroy(gctx.device, &img)
      return
    }
  }
  h, ok := cont.slots_alloc(&r.texture_slots)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return 0, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  r.textures[h] = img
  gpu.write_descriptor(gctx, r.scene.bindless_set, BINDING_TEXTURES, h, .SAMPLED_IMAGE, vk.DescriptorImageInfo{imageView = img.view, imageLayout = .GENERAL})
  return TextureHandle(h), .SUCCESS
}

// destroy_texture invalidates handle at once; its slot and image are released once no
// frame in flight samples them. shutdown frees every texture.
destroy_texture :: proc(r: ^Renderer, handle: TextureHandle) {
  guard(r)
  cont.slots_free(&r.texture_slots, u32(handle))
}

// NO_TEXTURE is the TextureHandle of none, as materials, emitters and draw2d commands hold it.
NO_TEXTURE :: 0

// create_texture_from_data decodes an encoded image (png, jpg, hdr, ...) held in memory
// into a bindless 2D texture. A float format decodes it as linear HDR.
create_texture_from_data :: proc(
  r: ^Renderer,
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
    return 0, .ERROR_UNKNOWN
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

// create_texture_from_path loads an image file (png, jpg, hdr, ...) into a bindless 2D texture.
create_texture_from_path :: proc(
  r: ^Renderer,
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
    return 0, .ERROR_UNKNOWN
  }
  defer delete(data)
  return create_texture_from_data(r, data, format, generate_mips)
}
