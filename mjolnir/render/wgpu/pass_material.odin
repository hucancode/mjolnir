package wgpu_backend

import wgpu "vendor:wgpu"

// AttachmentType names the images a camera renders into.
AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  NORMAL             = 1,
  ALBEDO             = 2,
  METALLIC_ROUGHNESS = 3,
  EMISSIVE           = 4,
  DEPTH              = 5,
}

// Each camera attachment's texture; pipelines drawing into an attachment take its format.
ATTACHMENTS :: [AttachmentType]TextureDesc {
  .FINAL_IMAGE        = {format = HDR_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLED}},
  .NORMAL             = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  .ALBEDO             = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  .METALLIC_ROUGHNESS = {format = .RGBA8_UNORM, usage = {.COLOR_TARGET, .SAMPLED}},
  // HDR, feeds bloom
  .EMISSIVE           = {format = .RGBA16F, usage = {.COLOR_TARGET, .SAMPLED}},
  // the depth pyramid build reads it
  .DEPTH              = {format = .D32F, usage = {.DEPTH_TARGET, .SAMPLED}, shared = true},
}

// How a material is drawn: one pipeline per type, drawn in this order. The types before
// FIRST_FORWARD_TYPE are opaque: drawn into the G-buffer, lit by the lighting pass, tested
// against the depth pyramid and drawn into shadow maps. The rest are drawn forward,
// alpha-blended over the lit image.
MaterialType :: enum u32 {
  PBR,
  TRANSPARENT,
  WIREFRAME,
  RANDOM_COLOR,
  // camera-facing billboard showing one cell of the albedo sprite sheet
  SPRITE,
}
FIRST_FORWARD_TYPE :: MaterialType.TRANSPARENT

@(private)
MaterialPass :: enum {
  // writes the G-buffer and depth, lit by the lighting pass
  GBUFFER,
  // alpha-blends into the lit image, depth-tested without writing
  FORWARD,
}

@(private = "file")
COMMON :: #load("shader/common.wgsl", string)
@(private = "file")
MESH :: COMMON + #load("shader/mesh.wgsl", string)

// Wireframe and random-color pull their vertices from the index buffer (no line polygon mode,
// no primitive index in core WebGPU): mesh_pulled.wgsl.
@(private = "file")
MATERIAL_SHADERS := [MaterialType]struct {
  source:   string,
  topology: wgpu.PrimitiveTopology,
  cull:     wgpu.CullMode,
} {
  .PBR          = {MESH + #load("shader/gbuffer.wgsl", string), .TriangleList, .Back},
  .TRANSPARENT  = {MESH + #load("shader/transparent.wgsl", string), .TriangleList, .Back},
  .WIREFRAME    = {COMMON + #load("shader/mesh_pulled.wgsl", string) + #load("shader/wireframe.wgsl", string), .LineList, .None},
  .RANDOM_COLOR = {COMMON + #load("shader/mesh_pulled.wgsl", string) + #load("shader/random_color.wgsl", string), .TriangleList, .Back},
  .SPRITE       = {COMMON + #load("shader/sprite.wgsl", string), .TriangleList, .None},
}

@(private = "file")
MATERIAL_PASS_TARGETS := [MaterialPass][]AttachmentType {
  .GBUFFER = {.NORMAL, .ALBEDO, .METALLIC_ROUGHNESS, .EMISSIVE},
  .FORWARD = {.FINAL_IMAGE},
}

@(private)
MATERIAL_PASS_TYPES := [MaterialPass][2]MaterialType {
  .GBUFFER = {MaterialType(0), FIRST_FORWARD_TYPE},
  .FORWARD = {FIRST_FORWARD_TYPE, MaterialType(len(MaterialType))},
}

// The pipeline fields of a material pass's targets.
@(private)
material_pass_desc :: proc(pass: MaterialPass, desc: ^GraphicsPipelineDesc) {
  targets := MATERIAL_PASS_TARGETS[pass]
  formats := make([]wgpu.TextureFormat, len(targets), context.temp_allocator)
  attachments := ATTACHMENTS
  for a, i in targets do formats[i] = FORMATS[attachments[a].format]
  desc.color_formats = formats
  desc.blend = &BLEND_ALPHA if pass == .FORWARD else nil
  desc.depth = true
  desc.depth_write = pass == .GBUFFER
  desc.depth_compare = .LessEqual
  desc.fragment = true
}

@(private)
material_pipelines_init :: proc(b: ^Backend) {
  for pass in MaterialPass {
    types := MATERIAL_PASS_TYPES[pass]
    for type in types[0] ..< types[1] {
      shaders := MATERIAL_SHADERS[type]
      desc := GraphicsPipelineDesc {
        source         = shaders.source,
        scene          = .MESH,
        textures       = .MATERIAL,
        vertex_buffers = mesh_vertex_buffers(),
        topology       = shaders.topology,
        cull           = shaders.cull,
      }
      material_pass_desc(pass, &desc)
      b.material_pipelines[type] = graphics_pipeline(b, desc)
    }
  }
}

// The forward pass draws particles first.
@(private)
material_pass_record :: proc(b: ^Backend, desc: ^FrameDesc, encoder: wgpu.CommandEncoder, cam: ^FrameCamera, pass: MaterialPass) {
  targets := MATERIAL_PASS_TARGETS[pass]
  colors := make([]wgpu.RenderPassColorAttachment, len(targets), context.temp_allocator)
  load: wgpu.LoadOp = .Clear if pass == .GBUFFER else .Load
  for a, i in targets {
    colors[i] = {view = b.textures[cam.attachments[a]].view, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = load, storeOp = .Store}
  }
  depth := wgpu.RenderPassDepthStencilAttachment {
    view            = b.textures[cam.attachments[.DEPTH]].view,
    depthLoadOp     = load if pass == .GBUFFER else .Undefined,
    depthStoreOp    = .Store if pass == .GBUFFER else .Undefined,
    depthClearValue = 1,
    depthReadOnly   = pass == .FORWARD,
  }
  rp := wgpu.CommandEncoderBeginRenderPass(
    encoder,
    &{colorAttachmentCount = len(colors), colorAttachments = raw_data(colors), depthStencilAttachment = &depth},
  )
  defer {
    wgpu.RenderPassEncoderEnd(rp)
    wgpu.RenderPassEncoderRelease(rp)
  }
  camera := cam.index
  offset := uniform(b, &camera)
  wgpu.RenderPassEncoderSetBindGroup(rp, 2, b.frame_group, {offset})
  if pass == .FORWARD do particles_draw(b, desc, rp, cam.index)
  wgpu.RenderPassEncoderSetBindGroup(rp, 0, b.scene_groups[.MESH])
  mesh_buffers_bind(b, rp)
  types := MATERIAL_PASS_TYPES[pass]
  draw_candidates(b, desc, rp, cam.next_slot, 0, MATERIAL_TYPES[types[0]:types[1]], b.material_pipelines[types[0]:types[1]])
}

@(private)
MATERIAL_TYPES := [len(MaterialType)]MaterialType{.PBR, .TRANSPARENT, .WIREFRAME, .RANDOM_COLOR, .SPRITE}

@(private)
mesh_buffers_bind :: proc(b: ^Backend, rp: wgpu.RenderPassEncoder) {
  wgpu.RenderPassEncoderSetVertexBuffer(rp, 0, b.mesh_buffers[.VERTEX], 0, wgpu.BufferGetSize(b.mesh_buffers[.VERTEX]))
  wgpu.RenderPassEncoderSetIndexBuffer(rp, b.mesh_buffers[.INDEX], .Uint32, 0, wgpu.BufferGetSize(b.mesh_buffers[.INDEX]))
}
