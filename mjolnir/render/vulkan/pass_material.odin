package vulkan_backend

import rhi "../rhi"

import vk "vendor:vulkan"




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

MATERIAL_SHADERS := [rhi.MaterialType]struct {
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
  colors: []rhi.AttachmentType,
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

MATERIAL_PASS_TYPES := [MaterialPass][2]rhi.MaterialType {
  .GBUFFER = {rhi.MaterialType(0), rhi.FIRST_FORWARD_TYPE},
  .FORWARD = {rhi.FIRST_FORWARD_TYPE, rhi.MaterialType(len(rhi.MaterialType))},
}

@(private)
material_pass_desc :: proc(pass: MaterialPass, desc: ^GraphicsPipelineDesc) {
  t := &MATERIAL_PASS_TARGETS[pass]
  formats := make([]vk.Format, len(t.colors), context.temp_allocator)
  blend := make([]vk.PipelineColorBlendAttachmentState, len(t.colors), context.temp_allocator)
  attachments := rhi.ATTACHMENTS
  for a, i in t.colors {
    formats[i] = FORMATS[attachments[a].format]
    blend[i] = t.blend
  }
  desc.color_formats = formats
  desc.blend = blend
  desc.depth = t.depth
  desc.depth_format = FORMATS[rhi.ATTACHMENTS[.DEPTH].format]
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
material_pass_record :: proc(b: ^Backend, frame_index: u32, cam: ^rhi.FrameCamera, pass: MaterialPass) {
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
