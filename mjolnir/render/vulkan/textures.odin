package vulkan_backend

import rhi "../rhi"

import "core:log"
import vk "vendor:vulkan"






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
BINDLESS_BINDINGS := [?]DescriptorBinding {
  BINDING_TEXTURES         = {.SAMPLED_IMAGE, rhi.MAX_TEXTURES, SCENE_STAGES},
  BINDING_SAMPLERS         = {.SAMPLER, len(SamplerType), SCENE_STAGES},
  BINDING_STORAGE_IMAGES   = {.STORAGE_IMAGE, MAX_STORAGE_IMAGES, {.COMPUTE}},
  BINDING_DRAW_LISTS       = {.STORAGE_BUFFER, MAX_DRAW_LIST_SLOTS, {.COMPUTE}},
  BINDING_PYRAMID_COUNTERS = {.STORAGE_BUFFER, 1, {.COMPUTE}},
}

// The bindless samplers; shaders index them with these values as literals.
@(private)
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

@(private)
FORMATS := [rhi.TextureFormat]vk.Format {
  .RGBA8_SRGB  = .R8G8B8A8_SRGB,
  .RGBA8_UNORM = .R8G8B8A8_UNORM,
  .RGBA16F     = .R16G16B16A16_SFLOAT,
  .RGBA32F     = .R32G32B32A32_SFLOAT,
  .R32F        = .R32_SFLOAT,
  .A8          = .R8_UNORM,
  .D32F        = .D32_SFLOAT,
}

@(private = "file")
USAGES := [rhi.TextureUsage]vk.ImageUsageFlags {
  .SAMPLED      = {.SAMPLED},
  .COLOR_TARGET = {.COLOR_ATTACHMENT},
  .DEPTH_TARGET = {.DEPTH_STENCIL_ATTACHMENT},
  .STORAGE      = {.STORAGE, .TRANSFER_DST},
}

// After the scene buffers, before pipeline layouts are built.
@(private)
bindless_init :: proc(b: ^Backend) -> vk.Result {
  gctx := &b.gctx
  d := &b.scene
  d.bindless_layout = create_descriptor_layout(gctx, ..BINDLESS_BINDINGS[:]) or_return
  for &sampler, type in b.samplers {
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
  allocate_descriptor_set(gctx, &d.bindless_set, &d.bindless_layout) or_return
  for sampler, type in b.samplers {
    write_descriptor(gctx, d.bindless_set, BINDING_SAMPLERS, u32(type), .SAMPLER, vk.DescriptorImageInfo{sampler = sampler})
  }
  write_descriptor(gctx, d.bindless_set, BINDING_PYRAMID_COUNTERS, 0, .STORAGE_BUFFER, buffer_info(&b.pyramid_counters))
  return .SUCCESS
}

@(private)
bindless_shutdown :: proc(b: ^Backend) {
  for &sampler in b.samplers {
    vk.DestroySampler(b.gctx.device, sampler, nil)
    sampler = 0
  }
  vk.DestroyDescriptorSetLayout(b.gctx.device, b.scene.bindless_layout, nil)
  b.scene.bindless_layout = 0
}

// texture_create makes the texture of handle and binds it in the bindless array. `data`
// fills level 0; the other levels are blitted down. A cube aliases the same binding as the
// shaders' textureCube array.
texture_create :: proc(b: ^Backend, handle: rhi.TextureHandle, desc: rhi.TextureDesc, data: []u8 = nil) -> bool {
  img, res := image_from_desc(b, desc, data)
  if res != .SUCCESS {
    log.errorf("Texture %d (%v %dx%d) creation failed: %v", handle, desc.format, desc.extent.x, desc.extent.y, res)
    return false
  }
  b.textures[handle] = img
  write_descriptor(&b.gctx, b.scene.bindless_set, BINDING_TEXTURES, u32(handle), .SAMPLED_IMAGE, vk.DescriptorImageInfo{imageView = img.view, imageLayout = .GENERAL})
  return true
}

@(private = "file")
image_from_desc :: proc(b: ^Backend, desc: rhi.TextureDesc, data: []u8) -> (img: Image, ret: vk.Result) {
  gctx := &b.gctx
  usage: vk.ImageUsageFlags
  for u in desc.usage do usage |= USAGES[u]
  if data != nil do usage |= {.TRANSFER_DST, .TRANSFER_SRC}
  // A8 coverage samples as white with alpha = coverage, so shaders multiply every sample with the color
  swizzle := vk.ComponentMapping{r = .ONE, g = .ONE, b = .ONE, a = .R} if desc.format == .A8 else {}
  extent := vk.Extent2D{desc.extent.x, desc.extent.y}
  img = image_create(gctx, extent, FORMATS[desc.format], usage, max(desc.mip_levels, 1), cube = desc.cube, shared = desc.shared, components = swizzle) or_return
  if data != nil {
    if ret = queue_image_write(gctx, &img, raw_data(data), len(data)); ret != .SUCCESS {
      image_destroy(gctx.device, &img)
      return
    }
  }
  // depth leaves UNDEFINED next frame; compute of the frame after is the first reader
  if .DEPTH_TARGET in desc.usage {
    queue_image_init(gctx, {img.image, {.DEPTH}, {.DEPTH_STENCIL_ATTACHMENT_READ}, {.EARLY_FRAGMENT_TESTS}})
  }
  return img, .SUCCESS
}

// texture_destroy destroys handle's texture at once: render retires the handle first.
texture_destroy :: proc(b: ^Backend, handle: rhi.TextureHandle) {
  image_destroy(b.gctx.device, &b.textures[handle])
}

@(private)
texture_image :: proc(b: ^Backend, handle: rhi.TextureHandle) -> ^Image {
  img := &b.textures[handle]
  return img if img.image != 0 else nil
}
