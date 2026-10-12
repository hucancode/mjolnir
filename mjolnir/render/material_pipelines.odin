#+private
package render

import "gpu"
import vk "vendor:vulkan"

// The pass whose render scope draws a material type's list.
MaterialPass :: enum {
  // writes the G-buffer and depth, lit by the lighting pass
  GBUFFER,
  // alpha-blends into the lit image, depth-tested without writing
  FORWARD,
}

// Everything that sets one material type apart. The cull shaders get the
// `occlusion` and `shadow` columns as bitmasks indexed by type.
MaterialPipelineDesc :: struct {
  vert:         []u8,
  frag:         []u8,
  pass:         MaterialPass,
  polygon_mode: vk.PolygonMode,
  cull_mode:    vk.CullModeFlags,
  // tested against the camera's depth pyramid
  occlusion:    bool,
  // drawn into shadow maps
  shadow:       bool,
}

// The geometry pass's vertex shader; its outputs feed every mesh fragment
// shader.
@(private = "file")
MESH_VERT :: #load("shader/gbuffer/vert.spv")

MATERIAL_PIPELINES := [MaterialType]MaterialPipelineDesc {
  .PBR = {
    vert = MESH_VERT,
    frag = #load("shader/gbuffer/frag.spv"),
    pass = .GBUFFER,
    polygon_mode = .FILL,
    cull_mode = {.BACK},
    occlusion = true,
    shadow = true,
  },
  .TRANSPARENT = {
    vert = MESH_VERT,
    frag = #load("shader/transparent/frag.spv"),
    pass = .FORWARD,
    polygon_mode = .FILL,
    cull_mode = {.BACK},
  },
  .WIREFRAME = {
    vert = MESH_VERT,
    frag = #load("shader/wireframe/frag.spv"),
    pass = .FORWARD,
    polygon_mode = .LINE,
  },
  .RANDOM_COLOR = {
    vert = MESH_VERT,
    frag = #load("shader/random_color/frag.spv"),
    pass = .FORWARD,
    polygon_mode = .FILL,
    cull_mode = {.BACK},
  },
  .SPRITE = {
    vert = #load("shader/sprite/vert.spv"),
    frag = #load("shader/sprite/frag.spv"),
    pass = .FORWARD,
    polygon_mode = .FILL,
  },
}

// The render targets of each pass's scope, which every pipeline drawing in it
// matches: `colors` and the camera depth, all loaded with `load`.
MaterialPassTargets :: struct {
  colors: []AttachmentType,
  blend:  vk.PipelineColorBlendAttachmentState,
  depth:  vk.PipelineDepthStencilStateCreateInfo,
  load:   vk.AttachmentLoadOp,
}

MATERIAL_PASS_TARGETS := [MaterialPass]MaterialPassTargets {
  .GBUFFER = {
    colors = {.NORMAL, .ALBEDO, .METALLIC_ROUGHNESS, .EMISSIVE},
    blend = gpu.BLEND_OVERRIDE,
    depth = gpu.READ_WRITE_DEPTH_STATE,
    load = .CLEAR,
  },
  .FORWARD = {
    colors = {.FINAL_IMAGE},
    blend = gpu.BLEND_ALPHA,
    depth = gpu.READ_ONLY_DEPTH_STATE,
    load = .LOAD,
  },
}

// Set `desc`'s render target state to `pass`'s scope.
material_pass_desc :: proc(pass: MaterialPass, desc: ^gpu.GraphicsPipelineDesc) {
  t := &MATERIAL_PASS_TARGETS[pass]
  formats := make([]vk.Format, len(t.colors), context.temp_allocator)
  blend := make([]vk.PipelineColorBlendAttachmentState, len(t.colors), context.temp_allocator)
  for a, i in t.colors {
    formats[i] = ATTACHMENTS[a].format
    blend[i] = t.blend
  }
  desc.color_formats = formats
  desc.blend = blend
  desc.depth = t.depth
  desc.depth_format = ATTACHMENTS[.DEPTH].format
}

// Bit t of `occlusion` / `shadow` is set when MATERIAL_PIPELINES[t].occlusion
// / .shadow is.
material_masks :: proc() -> (occlusion, shadow: u32) {
  for desc, type in MATERIAL_PIPELINES {
    if desc.occlusion do occlusion |= 1 << u32(type)
    if desc.shadow do shadow |= 1 << u32(type)
  }
  return
}

material_pipelines_init :: proc(r: ^Manager) -> vk.Result {
  for desc, type in MATERIAL_PIPELINES {
    pipeline := gpu.GraphicsPipelineDesc {
      vert = desc.vert,
      frag = desc.frag,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      polygon_mode = desc.polygon_mode,
      cull_mode = desc.cull_mode,
      layout = r.scene.layout,
    }
    material_pass_desc(desc.pass, &pipeline)
    r.material_pipelines[type] = gpu.create_graphics_pipeline(&r.gctx, pipeline) or_return
  }
  return .SUCCESS
}

// Record one camera's render scope of `pass`: the forward pass draws the
// particles first, then every material type drawn by `pass` draws its list
// from the camera's draw lists, in MaterialType order. A camera draws no list
// until a cull has written them. record_camera_passes orders the scopes.
material_pass_record :: proc(
  r: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
  pass: MaterialPass,
) {
  cmd := r.command_buffers[frame_index]
  t := &MATERIAL_PASS_TARGETS[pass]
  colors := make([]vk.RenderingAttachmentInfo, len(t.colors), context.temp_allocator)
  for a, i in t.colors do colors[i] = gpu.create_color_attachment(camera_image(r, cam, a, frame_index).view, t.load)
  depth := camera_image(r, cam, .DEPTH, frame_index)
  gpu.begin_rendering(cmd, depth.extent, gpu.create_depth_attachment(depth.view, t.load), ..colors)
  push := cam_index
  push_constants(r, cmd, &push)
  if pass == .FORWARD do particles_draw(r, cmd)
  if r.gctx.frame_serial >= cam.ready_serial {
    bind_mesh_buffers(r, cmd)
    for desc, type in MATERIAL_PIPELINES {
      if desc.pass != pass do continue
      vk.CmdBindPipeline(cmd, .GRAPHICS, r.material_pipelines[type])
      draw_lists_draw(&cam.draws, cmd, frame_index, u32(type))
    }
  }
  vk.CmdEndRendering(cmd)
}
