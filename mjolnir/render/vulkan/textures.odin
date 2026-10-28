#+private
package vulkan_backend

import rhi "../rhi"

import "core:log"
import vk "vendor:vulkan"






// Storage image slots: the pyramids' mips (MAX_PYRAMID_SLOTS), then the IBL precompute targets,
// then the cameras' lit images, one per pyramid slot.
@(private)
MAX_STORAGE_IMAGES :: MAX_PYRAMID_SLOTS * rhi.MAX_DEPTH_MIPS + rhi.PRECOMPUTE_TARGETS + MAX_PYRAMID_SLOTS

@(private)
SCENE_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

// Bindings of the bindless set (set 1). Shaders repeat these numbers as
// literals.
@(private)
BINDING_TEXTURES :: 0 // [MAX_TEXTURES] sampled images, 2D and cube
@(private)
BINDING_SAMPLERS :: 1 // one sampler per rhi.SamplerType
@(private)
BINDING_STORAGE_IMAGES :: 2 // [MAX_STORAGE_IMAGES] depth pyramid mips, IBL precompute targets, lit images
@(private)
BINDING_DRAW_LISTS :: 3 // [MAX_DRAW_LIST_SLOTS] indirect draw list buffers
@(private)
BINDING_PYRAMID_COUNTERS :: 4 // one u32 per depth pyramid
@(private)
BINDLESS_BINDINGS := [?]DescriptorBinding {
  BINDING_TEXTURES         = {.SAMPLED_IMAGE, rhi.MAX_TEXTURES, SCENE_STAGES},
  BINDING_SAMPLERS         = {.SAMPLER, len(rhi.SamplerType), SCENE_STAGES},
  BINDING_STORAGE_IMAGES   = {.STORAGE_IMAGE, MAX_STORAGE_IMAGES, {.COMPUTE}},
  BINDING_DRAW_LISTS       = {.STORAGE_BUFFER, MAX_DRAW_LIST_SLOTS, {.COMPUTE}},
  BINDING_PYRAMID_COUNTERS = {.STORAGE_BUFFER, 1, {.COMPUTE}},
}

@(private = "file")
SAMPLERS := [rhi.SamplerType]struct {
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
  .BACKBUFFER  = .UNDEFINED,
}

@(private = "file")
USAGES := [rhi.TextureUsage]vk.ImageUsageFlags {
  .SAMPLED      = {.SAMPLED},
  .COLOR_TARGET = {.COLOR_ATTACHMENT},
  .DEPTH_TARGET = {.DEPTH_STENCIL_ATTACHMENT},
  .STORAGE      = {.STORAGE, .TRANSFER_DST},
}

// Before pipeline layouts are built.
@(private)
bindless_init :: proc(b: ^Backend) -> vk.Result {
  gctx := &b.gctx
  b.bindless_layout = create_descriptor_layout(gctx, ..BINDLESS_BINDINGS[:]) or_return
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
  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = gctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &b.bindless_layout,
  }
  vk.AllocateDescriptorSets(gctx.device, &alloc_info, &b.bindless_set) or_return
  for sampler, type in b.samplers {
    write_descriptor(gctx, b.bindless_set, BINDING_SAMPLERS, u32(type), .SAMPLER, vk.DescriptorImageInfo{sampler = sampler})
  }
  return .SUCCESS
}

@(private)
bindless_shutdown :: proc(b: ^Backend) {
  for &sampler in b.samplers {
    vk.DestroySampler(b.gctx.device, sampler, nil)
    sampler = 0
  }
  vk.DestroyDescriptorSetLayout(b.gctx.device, b.bindless_layout, nil)
  b.bindless_layout = 0
}

// texture_create makes the texture of handle and binds it in the bindless array. `data`
// fills level 0; the other levels are blitted down. A cube aliases the same binding as the
// shaders' textureCube array.
texture_create :: proc(b: ^Backend, handle: rhi.TextureHandle, desc: rhi.TextureDesc, data: []u8) -> bool {
  img, res := image_from_desc(b, desc, data)
  if res != .SUCCESS {
    log.errorf("Texture %d (%v %dx%d) creation failed: %v", handle, desc.format, desc.extent.x, desc.extent.y, res)
    return false
  }
  b.textures[handle] = img
  write_descriptor(&b.gctx, b.bindless_set, BINDING_TEXTURES, u32(handle), .SAMPLED_IMAGE, vk.DescriptorImageInfo{imageView = img.view, imageLayout = .GENERAL})
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
  img = image_create(gctx, extent, FORMATS[desc.format], usage, max(desc.mip_levels, 1), cube = desc.cube, layers = max(desc.layers, 1), array = desc.layers > 1, shared = desc.shared, components = swizzle) or_return
  if data != nil {
    if ret = queue_image_write(gctx, &img, raw_data(data), len(data)); ret != .SUCCESS {
      image_destroy(gctx, &img)
      return
    }
  }
  // storage images are written by compute before anything else touches them
  if .STORAGE in desc.usage && data == nil {
    queue_image_init(gctx, {img.image, {.COLOR}, {.SHADER_READ, .SHADER_WRITE}, {.COMPUTE_SHADER}})
  }
  // depth leaves UNDEFINED next frame; compute of the frame after is the first reader
  if .DEPTH_TARGET in desc.usage {
    queue_image_init(gctx, {img.image, {.DEPTH}, {.DEPTH_STENCIL_ATTACHMENT_READ}, {.EARLY_FRAGMENT_TESTS}})
  }
  return img, .SUCCESS
}

// texture_destroy destroys handle's texture at once: render retires the handle first.
texture_destroy :: proc(b: ^Backend, handle: rhi.TextureHandle) {
  image_destroy(&b.gctx, &b.textures[handle])
}

@(private)
texture_image :: proc(b: ^Backend, handle: rhi.TextureHandle) -> ^Image {
  img := &b.textures[handle]
  return img if img.image != 0 else nil
}
