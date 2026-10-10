package forward

import "../bindless"
import "../gpu"
import vk "vendor:vulkan"

// What distinguishes one forward pipeline from another. Every forward
// pipeline reads depth without writing it, alpha-blends into the HDR target
// and pushes the camera index.
ForwardPipelineDesc :: struct {
  vert:         []u8,
  frag:         []u8,
  sets:         bindless.SceneSets,
  topology:     vk.PrimitiveTopology,
  polygon_mode: vk.PolygonMode,
  cull_mode:    vk.CullModeFlags,
}

// OPAQUE is drawn by the geometry pass.
PIPELINES := #partial [bindless.DrawPipeline]ForwardPipelineDesc {
  .TRANSPARENT = {
    vert = #load("../shader/transparent/vert.spv"),
    frag = #load("../shader/transparent/frag.spv"),
    sets = bindless.MESH_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .FILL,
    cull_mode = {.BACK},
  },
  .WIREFRAME = {
    vert = #load("../shader/wireframe/vert.spv"),
    frag = #load("../shader/wireframe/frag.spv"),
    sets = bindless.MESH_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .LINE,
  },
  .RANDOM_COLOR = {
    vert = #load("../shader/random_color/vert.spv"),
    frag = #load("../shader/random_color/frag.spv"),
    sets = bindless.MESH_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .FILL,
    cull_mode = {.BACK},
  },
  .LINE_STRIP = {
    vert = #load("../shader/line_strip/vert.spv"),
    frag = #load("../shader/line_strip/frag.spv"),
    sets = bindless.MESH_SETS,
    topology = .LINE_STRIP,
    polygon_mode = .LINE,
  },
  .SPRITE = {
    vert = #load("../shader/sprite/vert.spv"),
    frag = #load("../shader/sprite/frag.spv"),
    sets = bindless.SPRITE_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .FILL,
  },
}

Renderer :: struct {
  pipeline_layouts: [bindless.DrawPipeline]vk.PipelineLayout,
  pipelines:        [bindless.DrawPipeline]vk.Pipeline,
}

PushConstant :: struct {
  camera_index: u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  scene: bindless.SceneBindings,
) -> vk.Result {
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ADDITIVE}
  for desc, pipe in PIPELINES {
    if pipe == .OPAQUE do continue
    self.pipeline_layouts[pipe] = bindless.create_scene_pipeline_layout(
      gctx,
      scene,
      desc.sets,
      {stageFlags = {.VERTEX, .FRAGMENT}, size = size_of(PushConstant)},
    ) or_return
    vert_module := gpu.create_shader_module(gctx.device, desc.vert) or_return
    defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
    frag_module := gpu.create_shader_module(gctx.device, desc.frag) or_return
    defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
    self.pipelines[pipe] = gpu.create_graphics_pipeline(
      gctx,
      {
        vert = vert_module,
        frag = frag_module,
        specialization = &bindless.SHADER_SPEC_CONSTANTS,
        vertex_bindings = bindless.VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = bindless.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
        topology = desc.topology,
        raster = {
          polygonMode = desc.polygon_mode,
          cullMode = desc.cull_mode,
          frontFace = .COUNTER_CLOCKWISE,
          lineWidth = 1,
        },
        depth = gpu.READ_ONLY_DEPTH_STATE,
        blend = blend[:],
        color_formats = color_formats[:],
        depth_format = .D32_SFLOAT,
        layout = self.pipeline_layouts[pipe],
      },
    ) or_return
  }
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  for pipe in bindless.DrawPipeline {
    vk.DestroyPipeline(gctx.device, self.pipelines[pipe], nil)
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layouts[pipe], nil)
  }
  self^ = {}
}

// record draws one forward pipeline inside the caller's render scope.
record :: proc(
  self: ^Renderer,
  cmd: vk.CommandBuffer,
  pipe: bindless.DrawPipeline,
  camera_index: u32,
  scene: bindless.SceneBindings,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
  max_draw_count: u32,
) {
  layout := self.pipeline_layouts[pipe]
  bindless.bind_scene(
    cmd,
    self.pipelines[pipe],
    layout,
    scene,
    PIPELINES[pipe].sets,
  )
  push_constants := PushConstant {
    camera_index = camera_index,
  }
  vk.CmdPushConstants(
    cmd,
    layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    draw_buffer,
    0,
    count_buffer,
    0,
    max_draw_count,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
}
