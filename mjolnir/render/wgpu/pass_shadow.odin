package wgpu_backend

import wgpu "vendor:wgpu"

MAX_SHADOW_MAPS :: 16
SHADOW_MAP_SIZE :: 512
// a cube map renders six views
MAX_SHADOW_VIEWS :: MAX_SHADOW_MAPS * 6

@(private = "file")
SHADOW_SLOPE_BIAS :: 1.5

@(private = "file")
SHADOW_WGSL :: #load("shader/common.wgsl", string) + #load("shader/shadow.wgsl", string)

// The atlas is one depth array layer per shadow view, grown by doubling; without layered
// rendering each view renders its own pass into its layer. There is no depth clamp in core
// WebGPU: a caster behind a directional cascade's near plane is clipped.
@(private)
ShadowAtlas :: struct {
  texture: wgpu.Texture,
  // every layer, sampled by lighting
  view:    wgpu.TextureView,
  layers:  [MAX_SHADOW_VIEWS]wgpu.TextureView,
  count:   u32,
}

@(private)
shadow_init :: proc(b: ^Backend) {
  position := wgpu.VertexAttribute{format = .Float32x3, offset = 0, shaderLocation = 0}
  buffers := [?]wgpu.VertexBufferLayout {
    {stepMode = .Vertex, arrayStride = size_of(Vertex), attributeCount = 1, attributes = &position},
    {stepMode = .Instance, arrayStride = size_of(u32), attributeCount = 1, attributes = &NODE_ATTRIBUTE},
  }
  b.shadow_pipeline = graphics_pipeline(
    b,
    {
      source = SHADOW_WGSL,
      scene = .SHADOW,
      vertex_buffers = buffers[:],
      topology = .TriangleList,
      cull = .Back,
      depth = true,
      depth_write = true,
      depth_compare = .LessEqual,
      slope_bias = SHADOW_SLOPE_BIAS,
    },
  )
  shadow_atlas_reserve(b, 1)
}

// Doubles up to MAX_SHADOW_VIEWS; lighting's bind groups go with the old atlas.
@(private)
shadow_atlas_reserve :: proc(b: ^Backend, layers: u32) {
  atlas := &b.shadow_atlas
  if layers <= atlas.count do return
  count := max(layers, min(atlas.count * 2, MAX_SHADOW_VIEWS))
  shadow_atlas_release(atlas)
  atlas.texture = wgpu.DeviceCreateTexture(
    b.device,
    &{
      usage = {.RenderAttachment, .TextureBinding},
      dimension = ._2D,
      size = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, count},
      format = .Depth32Float,
      mipLevelCount = 1,
      sampleCount = 1,
    },
  )
  atlas.view = wgpu.TextureCreateView(atlas.texture, &{dimension = ._2DArray, mipLevelCount = 1, arrayLayerCount = count})
  for layer in 0 ..< count {
    atlas.layers[layer] = wgpu.TextureCreateView(atlas.texture, &{dimension = ._2D, mipLevelCount = 1, baseArrayLayer = layer, arrayLayerCount = 1})
  }
  atlas.count = count
  groups_clear(b)
}

@(private)
shadow_atlas_release :: proc(atlas: ^ShadowAtlas) {
  if atlas.texture == nil do return
  for view in atlas.layers[:atlas.count] do wgpu.TextureViewRelease(view)
  wgpu.TextureViewRelease(atlas.view)
  wgpu.TextureDestroy(atlas.texture)
  wgpu.TextureRelease(atlas.texture)
  atlas^ = {}
}

// One pass per shadow view; the cull wrote view v's draws after (v - SHADOW_VIEW_BASE) * stride.
@(private)
shadow_record :: proc(b: ^Backend, desc: ^FrameDesc, encoder: wgpu.CommandEncoder) {
  types := [1]MaterialType{.PBR}
  pipelines := [1]wgpu.RenderPipeline{b.shadow_pipeline}
  for v in 0 ..< desc.shadow_view_count {
    depth := wgpu.RenderPassDepthStencilAttachment {
      view            = b.shadow_atlas.layers[v],
      depthLoadOp     = .Clear,
      depthStoreOp    = .Store,
      depthClearValue = 1,
    }
    rp := wgpu.CommandEncoderBeginRenderPass(encoder, &{depthStencilAttachment = &depth})
    view := SHADOW_VIEW_BASE + v
    offset := uniform(b, &view)
    wgpu.RenderPassEncoderSetBindGroup(rp, 0, b.scene_groups[.SHADOW])
    wgpu.RenderPassEncoderSetBindGroup(rp, 1, group(b, {layout = .NONE}))
    wgpu.RenderPassEncoderSetBindGroup(rp, 2, b.frame_group, {offset})
    mesh_buffers_bind(b, rp)
    draw_candidates(b, desc, rp, desc.shadow_draw_list, v * b.shadow_stride, types[:], pipelines[:], b.shadow_stride, false)
    wgpu.RenderPassEncoderEnd(rp)
    wgpu.RenderPassEncoderRelease(rp)
  }
}
