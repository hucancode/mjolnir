package vulkan_backend

import vk "vendor:vulkan"

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

// How a material is drawn: one pipeline and, per camera, one indirect draw list per type,
// drawn in this order. The types before FIRST_FORWARD_TYPE are opaque: drawn into the
// G-buffer, lit by the lighting pass, tested against the depth pyramid and drawn into
// shadow maps. The rest are drawn forward, alpha-blended over the lit image.
MaterialType :: enum u32 {
  PBR,
  TRANSPARENT,
  WIREFRAME,
  RANDOM_COLOR,
  // camera-facing billboard showing one cell of the albedo sprite sheet
  SPRITE,
}
FIRST_FORWARD_TYPE :: MaterialType.TRANSPARENT

// Each MaterialType's pipeline is built against the targets of its pass (MATERIAL_PASS_TARGETS).
@(private)
MaterialPass :: enum {
  // writes the G-buffer and depth, lit by the lighting pass
  GBUFFER,
  // alpha-blends into the lit image, depth-tested without writing
  FORWARD,
}

// its outputs feed every mesh fragment shader
@(private = "file")
MESH_VERT :: #load("shader/gbuffer/vert.spv")

MATERIAL_SHADERS := [MaterialType]struct {
  vert, frag:   []u8,
  polygon_mode: vk.PolygonMode,
  cull_mode:    vk.CullModeFlags,
} {
  .PBR          = {vert = MESH_VERT, frag = #load("shader/gbuffer/frag.spv"), cull_mode = {.BACK}},
  .TRANSPARENT  = {vert = MESH_VERT, frag = #load("shader/transparent/frag.spv"), cull_mode = {.BACK}},
  .WIREFRAME    = {vert = MESH_VERT, frag = #load("shader/wireframe/frag.spv"), polygon_mode = .LINE},
  .RANDOM_COLOR = {vert = MESH_VERT, frag = #load("shader/random_color/frag.spv"), cull_mode = {.BACK}},
  .SPRITE       = {vert = #load("shader/sprite/vert.spv"), frag = #load("shader/sprite/frag.spv")},
}

// `colors` and the camera depth, all loaded with `load`.
@(private)
MaterialPassTargets :: struct {
  colors: []AttachmentType,
  blend:  vk.PipelineColorBlendAttachmentState,
  depth:  vk.PipelineDepthStencilStateCreateInfo,
  load:   vk.AttachmentLoadOp,
}

MATERIAL_PASS_TARGETS := [MaterialPass]MaterialPassTargets {
  .GBUFFER = {
    colors = {.NORMAL, .ALBEDO, .METALLIC_ROUGHNESS, .EMISSIVE},
    blend = BLEND_OVERRIDE,
    depth = READ_WRITE_DEPTH_STATE,
    load = .CLEAR,
  },
  .FORWARD = {
    colors = {.FINAL_IMAGE},
    blend = BLEND_ALPHA,
    depth = READ_ONLY_DEPTH_STATE,
    load = .LOAD,
  },
}

MATERIAL_PASS_TYPES := [MaterialPass][2]MaterialType {
  .GBUFFER = {MaterialType(0), FIRST_FORWARD_TYPE},
  .FORWARD = {FIRST_FORWARD_TYPE, MaterialType(len(MaterialType))},
}

@(private)
material_pass_desc :: proc(pass: MaterialPass, desc: ^GraphicsPipelineDesc) {
  t := &MATERIAL_PASS_TARGETS[pass]
  formats := make([]vk.Format, len(t.colors), context.temp_allocator)
  blend := make([]vk.PipelineColorBlendAttachmentState, len(t.colors), context.temp_allocator)
  attachments := ATTACHMENTS
  for a, i in t.colors {
    formats[i] = FORMATS[attachments[a].format]
    blend[i] = t.blend
  }
  desc.color_formats = formats
  desc.blend = blend
  desc.depth = t.depth
  desc.depth_format = FORMATS[ATTACHMENTS[.DEPTH].format]
}

@(private)
material_pipelines_init :: proc(b: ^Backend) -> vk.Result {
  for pass in MaterialPass {
    types := MATERIAL_PASS_TYPES[pass]
    for type in types[0] ..< types[1] {
      shaders := MATERIAL_SHADERS[type]
      // without fillModeNonSolid wireframe materials draw filled
      polygon_mode := shaders.polygon_mode
      if polygon_mode == .LINE && !b.gctx.fill_mode_non_solid do polygon_mode = .FILL
      pipeline := GraphicsPipelineDesc {
        vert = shaders.vert,
        frag = shaders.frag,
        vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
        topology = .TRIANGLE_LIST,
        polygon_mode = polygon_mode,
        cull_mode = shaders.cull_mode,
        layout = b.scene.layout,
      }
      material_pass_desc(pass, &pipeline)
      b.material_pipelines[type] = create_graphics_pipeline(&b.gctx, pipeline) or_return
    }
  }
  return .SUCCESS
}

// The forward pass draws particles first. A camera draws nothing until a cull has written its lists.
@(private)
material_pass_record :: proc(b: ^Backend, frame_index: u32, cam: ^FrameCamera, pass: MaterialPass) {
  cmd := b.command_buffers[frame_index]
  t := &MATERIAL_PASS_TARGETS[pass]
  colors := make([]vk.RenderingAttachmentInfo, len(t.colors), context.temp_allocator)
  for a, i in t.colors do colors[i] = create_color_attachment(texture_image(b, cam.attachments[a]).view, t.load)
  depth := texture_image(b, cam.attachments[.DEPTH])
  begin_rendering(cmd, depth.extent, create_depth_attachment(depth.view, t.load), ..colors)
  push := cam.index
  push_constants(b, cmd, &push)
  if pass == .FORWARD do particles_draw(b, cmd)
  if cam.ready {
    bind_mesh_buffers(b, cmd)
    types := MATERIAL_PASS_TYPES[pass]
    for type in types[0] ..< types[1] {
      vk.CmdBindPipeline(cmd, .GRAPHICS, b.material_pipelines[type])
      draw_lists_draw(b, cmd, cam.slot, u32(type))
    }
  }
  vk.CmdEndRendering(cmd)
}
