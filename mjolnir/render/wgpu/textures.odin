package wgpu_backend

import rhi "../rhi"

import "core:log"
import "core:math"
import wgpu "vendor:wgpu"






// A8 is stored as white RGBA with alpha = coverage (WebGPU has no swizzle), RGBA32F as
// RGBA16F so it filters without float32-filterable.
@(private)
FORMATS := [rhi.TextureFormat]wgpu.TextureFormat {
  .RGBA8_SRGB  = .RGBA8UnormSrgb,
  .RGBA8_UNORM = .RGBA8Unorm,
  .RGBA16F     = .RGBA16Float,
  .RGBA32F     = .RGBA16Float,
  .R32F        = .R32Float,
  .A8          = .RGBA8Unorm,
  .D32F        = .Depth32Float,
}

// Bytes per texel as stored.
@(private = "file")
TEXEL_SIZE := [rhi.TextureFormat]u32 {
  .RGBA8_SRGB  = 4,
  .RGBA8_UNORM = 4,
  .RGBA16F     = 8,
  .RGBA32F     = 8,
  .R32F        = 4,
  .A8          = 4,
  .D32F        = 4,
}

@(private = "file")
USAGES := [rhi.TextureUsage]wgpu.TextureUsageFlags {
  .SAMPLED      = {.TextureBinding},
  .COLOR_TARGET = {.RenderAttachment},
  .DEPTH_TARGET = {.RenderAttachment},
  .STORAGE      = {.StorageBinding},
}

// Shaders name the samplers by these (shader/common.wgsl binds them in group 2).
@(private)
SamplerType :: enum u32 {
  NEAREST_CLAMP,
  LINEAR_CLAMP,
  NEAREST_REPEAT,
  LINEAR_REPEAT,
  // bilinear depth comparison (2x2 PCF) for shadow maps
  SHADOW_COMPARE,
}

@(private = "file")
SAMPLERS := [SamplerType]struct {
  filter:  wgpu.FilterMode,
  address: wgpu.AddressMode,
  compare: wgpu.CompareFunction,
} {
  .NEAREST_CLAMP  = {.Nearest, .ClampToEdge, .Undefined},
  .LINEAR_CLAMP   = {.Linear, .ClampToEdge, .Undefined},
  .NEAREST_REPEAT = {.Nearest, .Repeat, .Undefined},
  .LINEAR_REPEAT  = {.Linear, .Repeat, .Undefined},
  // lit where the reference depth is at or in front of the stored one
  .SHADOW_COMPARE = {.Linear, .ClampToEdge, .LessEqual},
}

// A texture and its views: `view` covers every mip, as a cube for a cube texture.
@(private)
Texture :: struct {
  texture: wgpu.Texture,
  view:    wgpu.TextureView,
  desc:    rhi.TextureDesc,
}

@(private)
samplers_init :: proc(b: ^Backend) {
  for &sampler, type in b.samplers {
    s := SAMPLERS[type]
    sampler = wgpu.DeviceCreateSampler(
      b.device,
      &{
        addressModeU = s.address,
        addressModeV = s.address,
        addressModeW = s.address,
        magFilter = s.filter,
        minFilter = s.filter,
        mipmapFilter = .Linear,
        lodMaxClamp = 32,
        compare = s.compare,
        maxAnisotropy = 1,
      },
    )
  }
}

// The textures bound where a slot has none: white 2D, black cube, and the empty shadow atlas.
@(private)
defaults_init :: proc(b: ^Backend) {
  b.white = texture_make(b, {extent = {1, 1}, format = .RGBA8_UNORM, usage = {.SAMPLED}}, {255, 255, 255, 255})
  b.black_cube = texture_make(b, {extent = {1, 1}, format = .RGBA16F, usage = {.SAMPLED}, cube = true}, make([]u8, 6 * 8, context.temp_allocator))
}

// texture_create makes the texture of handle. `data` fills level 0; the other levels are
// rendered down from it.
texture_create :: proc(b: ^Backend, handle: rhi.TextureHandle, desc: rhi.TextureDesc, data: []u8 = nil) -> bool {
  b.textures[handle] = texture_make(b, desc, data)
  groups_clear(b)
  return b.textures[handle].texture != nil
}

// texture_destroy destroys handle's texture: WebGPU keeps it alive for submitted work.
texture_destroy :: proc(b: ^Backend, handle: rhi.TextureHandle) {
  texture_release(&b.textures[handle])
  groups_clear(b)
}

@(private)
texture_release :: proc(t: ^Texture) {
  if t.texture == nil do return
  wgpu.TextureViewRelease(t.view)
  wgpu.TextureDestroy(t.texture)
  wgpu.TextureRelease(t.texture)
  t^ = {}
}

@(private)
texture_make :: proc(b: ^Backend, desc: rhi.TextureDesc, data: []u8 = nil) -> (t: Texture) {
  usage: wgpu.TextureUsageFlags
  for u in desc.usage do usage += USAGES[u]
  mips := max(desc.mip_levels, 1)
  if data != nil do usage += {.CopyDst}
  if data != nil && mips > 1 do usage += {.RenderAttachment}
  layers: u32 = 6 if desc.cube else 1
  t.desc = desc
  t.texture = wgpu.DeviceCreateTexture(
    b.device,
    &{
      usage = usage,
      dimension = ._2D,
      size = {desc.extent.x, desc.extent.y, layers},
      format = FORMATS[desc.format],
      mipLevelCount = mips,
      sampleCount = 1,
    },
  )
  if t.texture == nil {
    log.errorf("Texture (%v %dx%d) creation failed", desc.format, desc.extent.x, desc.extent.y)
    return {}
  }
  t.view = wgpu.TextureCreateView(t.texture, &{dimension = .Cube if desc.cube else ._2D, mipLevelCount = mips, arrayLayerCount = layers})
  if data != nil {
    texels := stored_texels(desc.format, data)
    size := TEXEL_SIZE[desc.format]
    for layer in 0 ..< layers {
      layer_bytes := int(desc.extent.x * desc.extent.y * size)
      wgpu.QueueWriteTexture(
        b.queue,
        &{texture = t.texture, origin = {0, 0, layer}},
        &texels[int(layer) * layer_bytes],
        uint(layer_bytes),
        &{bytesPerRow = desc.extent.x * size, rowsPerImage = desc.extent.y},
        &{desc.extent.x, desc.extent.y, 1},
      )
    }
    if mips > 1 do mipmaps_generate(b, &t)
  }
  return
}

// data as the texture stores it, in the temp allocator.
@(private = "file")
stored_texels :: proc(format: rhi.TextureFormat, data: []u8) -> []u8 {
  #partial switch format {
  case .A8:
    out := make([]u8, len(data) * 4, context.temp_allocator)
    for a, i in data do out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = 255, 255, 255, a
    return out
  case .RGBA32F:
    src := ([^]f32)(raw_data(data))[:len(data) / 4]
    out := make([]f16, len(src), context.temp_allocator)
    for v, i in src do out[i] = f16(math.clamp(v, -65504, 65504))
    return ([^]u8)(raw_data(out))[:len(out) * 2]
  }
  return data
}

// Renders each level from the one above with a linear-filtered fullscreen triangle.
@(private = "file")
mipmaps_generate :: proc(b: ^Backend, t: ^Texture) {
  format := FORMATS[t.desc.format]
  pipeline := mipgen_pipeline(b, format)
  encoder := wgpu.DeviceCreateCommandEncoder(b.device)
  for mip in 1 ..< t.desc.mip_levels {
    src := wgpu.TextureCreateView(t.texture, &{dimension = ._2D, baseMipLevel = mip - 1, mipLevelCount = 1, arrayLayerCount = 1})
    dst := wgpu.TextureCreateView(t.texture, &{dimension = ._2D, baseMipLevel = mip, mipLevelCount = 1, arrayLayerCount = 1})
    entries := [?]wgpu.BindGroupEntry{{binding = 0, textureView = src}, {binding = 1, sampler = b.samplers[.LINEAR_CLAMP]}}
    group := wgpu.DeviceCreateBindGroup(b.device, &{layout = b.mipgen_layout, entryCount = len(entries), entries = raw_data(entries[:])})
    color := wgpu.RenderPassColorAttachment {
      view       = dst,
      depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
      loadOp     = .Clear,
      storeOp    = .Store,
    }
    pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{colorAttachmentCount = 1, colorAttachments = &color})
    wgpu.RenderPassEncoderSetPipeline(pass, pipeline)
    wgpu.RenderPassEncoderSetBindGroup(pass, 0, group)
    wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
    wgpu.RenderPassEncoderEnd(pass)
    wgpu.RenderPassEncoderRelease(pass)
    wgpu.BindGroupRelease(group)
    wgpu.TextureViewRelease(src)
    wgpu.TextureViewRelease(dst)
  }
  commands := wgpu.CommandEncoderFinish(encoder)
  wgpu.QueueSubmit(b.queue, {commands})
  wgpu.CommandBufferRelease(commands)
  wgpu.CommandEncoderRelease(encoder)
}

@(private = "file")
mipgen_pipeline :: proc(b: ^Backend, format: wgpu.TextureFormat) -> wgpu.RenderPipeline {
  for p in b.mipgen_pipelines do if p.format == format do return p.pipeline
  if b.mipgen_layout == nil {
    entries := [?]wgpu.BindGroupLayoutEntry {
      {binding = 0, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
      {binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
    }
    b.mipgen_layout = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(entries), entries = raw_data(entries[:])})
  }
  layouts := [?]wgpu.BindGroupLayout{b.mipgen_layout}
  layout := wgpu.DeviceCreatePipelineLayout(b.device, &{bindGroupLayoutCount = 1, bindGroupLayouts = raw_data(layouts[:])})
  defer wgpu.PipelineLayoutRelease(layout)
  module := shader_module(b, MIPGEN_WGSL)
  defer wgpu.ShaderModuleRelease(module)
  target := wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All}
  pipeline := wgpu.DeviceCreateRenderPipeline(
    b.device,
    &{
      layout = layout,
      vertex = {module = module, entryPoint = "vs_main"},
      primitive = {topology = .TriangleList},
      multisample = {count = 1, mask = 0xFFFFFFFF},
      fragment = &{module = module, entryPoint = "fs_main", targetCount = 1, targets = &target},
    },
  )
  append(&b.mipgen_pipelines, MipgenPipeline{format, pipeline})
  return pipeline
}

@(private = "file")
MIPGEN_WGSL :: #load("shader/mipgen.wgsl", string)

@(private)
MipgenPipeline :: struct {
  format:   wgpu.TextureFormat,
  pipeline: wgpu.RenderPipeline,
}

// Texture bind groups by what they bind; textures change only between frames (loads, resizes),
// so any change drops them all.
@(private)
GroupKey :: struct {
  layout:   GroupLayout,
  textures: [MAX_GROUP_TEXTURES]rhi.TextureHandle,
}

@(private)
groups_clear :: proc(b: ^Backend) {
  for _, group in b.groups do wgpu.BindGroupRelease(group)
  clear(&b.groups)
  cull_groups_clear(b)
}

// The bind group of key: its layout's texture slots take key.textures in order, a
// slot without a texture the default of its kind.
@(private)
group :: proc(b: ^Backend, key: GroupKey) -> wgpu.BindGroup {
  if g, ok := b.groups[key]; ok do return g
  slots := GROUP_LAYOUTS[key.layout]
  entries: [MAX_GROUP_TEXTURES]wgpu.BindGroupEntry
  for slot, i in slots {
    view: wgpu.TextureView
    switch slot {
    case .FLOAT, .UNFILTERABLE, .DEPTH:
      view = b.textures[key.textures[i]].view if key.textures[i] != 0 else b.white.view
    case .CUBE:
      view = b.textures[key.textures[i]].view if key.textures[i] != 0 else b.black_cube.view
    case .SHADOW_ATLAS:
      view = b.shadow_atlas.view
    }
    entries[i] = {binding = u32(i), textureView = view}
  }
  g := wgpu.DeviceCreateBindGroup(
    b.device,
    &{layout = b.group_layouts[key.layout], entryCount = uint(len(slots)), entries = raw_data(entries[:])},
  )
  b.groups[key] = g
  return g
}
