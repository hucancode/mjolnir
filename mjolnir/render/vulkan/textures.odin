#+private
package vulkan_backend

import rhi "../rhi"

import "base:builtin"

import "core:log"
import vk "vendor:vulkan"
@(private)
SCENE_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

// Bindings of the bindless set (set 1). Shaders repeat these numbers as
// literals.
@(private)
BINDING_TEXTURES :: 0 // [texture_slots] sampled images, 2D and cube
@(private)
BINDING_SAMPLERS :: 1 // one sampler per rhi.SamplerType
@(private)
BINDING_STORAGE_IMAGES :: 2 // [rhi.BindlessArray.STORAGE_IMAGES] storage images
@(private)
BINDING_STORAGE_BUFFERS :: 3 // [rhi.BindlessArray.STORAGE_BUFFERS] storage buffers
@(private)
BINDING_EXTRA_BUFFERS :: 4 // [rhi.BindlessArray.EXTRA_BUFFERS] storage buffers
@(private)
BINDLESS_ARRAY_BINDINGS := [rhi.BindlessArray]u32 {
  .STORAGE_IMAGES  = BINDING_STORAGE_IMAGES,
  .STORAGE_BUFFERS = BINDING_STORAGE_BUFFERS,
  .EXTRA_BUFFERS   = BINDING_EXTRA_BUFFERS,
}

// init's sizes, each at least 1: Vulkan takes no empty binding.
@(private)
bindless_sizes :: proc(b: ^Backend) -> (sizes: [rhi.BindlessArray]u32) {
  for n, a in b.bindless_sizes do sizes[a] = max(n, 1)
  return
}

// Descriptors of each type left to the bind group sets of a pipeline beside the bindless set.
@(private = "file")
BIND_GROUP_HEADROOM :: 64

// Fits the bindless arrays to the device's per-stage and per-set limits, the bind group sets'
// headroom kept: the texture array is rhi.MAX_TEXTURES long where the device allows, and the
// two storage buffer arrays share one limit. Before bindless_bindings.
@(private)
bindless_clamp :: proc(b: ^Backend) {
  limits := &b.gctx.device_properties.limits
  budget :: proc(per_stage, per_set: u32) -> u32 {
    n := min(per_stage, per_set)
    return max(n - min(BIND_GROUP_HEADROOM, n / 2), 1)
  }
  sizes := bindless_sizes(b)
  b.texture_slots = min(rhi.MAX_TEXTURES, budget(limits.maxPerStageDescriptorSampledImages, limits.maxDescriptorSetSampledImages))
  // the samplers and storage arrays count against the per-stage resources too
  others := len(rhi.SamplerType) + sizes[.STORAGE_IMAGES] + sizes[.STORAGE_BUFFERS] + sizes[.EXTRA_BUFFERS]
  resources := budget(limits.maxPerStageResources, limits.maxPerStageResources)
  if others < resources do b.texture_slots = min(b.texture_slots, resources - others)
  if b.texture_slots < rhi.MAX_TEXTURES do log.infof("Bindless textures clamped to %d of %d by the device limits", b.texture_slots, rhi.MAX_TEXTURES)
  clamped := sizes
  clamped[.STORAGE_IMAGES] = min(sizes[.STORAGE_IMAGES], budget(limits.maxPerStageDescriptorStorageImages, limits.maxDescriptorSetStorageImages))
  buffers := budget(limits.maxPerStageDescriptorStorageBuffers, limits.maxDescriptorSetStorageBuffers)
  clamped[.EXTRA_BUFFERS] = min(sizes[.EXTRA_BUFFERS], max(buffers / 2, 1))
  clamped[.STORAGE_BUFFERS] = min(sizes[.STORAGE_BUFFERS], max(buffers - clamped[.EXTRA_BUFFERS], 1))
  for n, a in clamped do if n < sizes[a] do log.infof("Bindless %v clamped to %d of %d by the device limits", a, n, sizes[a])
  b.bindless_sizes = clamped
}

@(private)
bindless_bindings :: proc(b: ^Backend) -> [5]DescriptorBinding {
  sizes := bindless_sizes(b)
  return {
    BINDING_TEXTURES        = {.SAMPLED_IMAGE, b.texture_slots, SCENE_STAGES},
    BINDING_SAMPLERS        = {.SAMPLER, len(rhi.SamplerType), SCENE_STAGES},
    BINDING_STORAGE_IMAGES  = {.STORAGE_IMAGE, sizes[.STORAGE_IMAGES], {.COMPUTE}},
    BINDING_STORAGE_BUFFERS = {.STORAGE_BUFFER, sizes[.STORAGE_BUFFERS], {.COMPUTE}},
    BINDING_EXTRA_BUFFERS   = {.STORAGE_BUFFER, sizes[.EXTRA_BUFFERS], {.COMPUTE}},
  }
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
  bindings := bindless_bindings(b)
  b.bindless_layout = create_descriptor_layout(gctx, ..bindings[:]) or_return
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
  if int(handle) >= len(b.textures) do builtin.resize(&b.textures, max(int(handle) + 1, 2 * len(b.textures), 256))
  b.textures[handle] = img
  if u32(handle) < b.texture_slots {
    write_descriptor(&b.gctx, b.bindless_set, BINDING_TEXTURES, u32(handle), .SAMPLED_IMAGE, vk.DescriptorImageInfo{imageView = img.view, imageLayout = .GENERAL})
  } else {
    log.warnf("Texture %d is past the device's %d bindless textures: not sampled through the array", handle, b.texture_slots)
  }
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
  img = image_create(gctx, desc, usage, swizzle) or_return
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
  if int(handle) < len(b.textures) do image_destroy(&b.gctx, &b.textures[handle])
}

// texture_desc is what handle's texture was made from (mip_levels and layers at least 1).
texture_desc :: proc(b: ^Backend, handle: rhi.TextureHandle) -> rhi.TextureDesc {
  return b.textures[handle].desc if int(handle) < len(b.textures) else {}
}

@(private)
texture_image :: proc(b: ^Backend, handle: rhi.TextureHandle) -> ^Image {
  if int(handle) >= len(b.textures) do return nil
  img := &b.textures[handle]
  return img if img.image != 0 else nil
}
