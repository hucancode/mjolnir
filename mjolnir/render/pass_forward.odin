#+private
package render

import "gpu"
import vk "vendor:vulkan"

// What distinguishes one forward pipeline from another. Every forward
// pipeline reads depth without writing it, alpha-blends into the HDR target
// and pushes the camera index.
ForwardPipelineDesc :: struct {
  vert:         []u8,
  frag:         []u8,
  sets:         SceneSets,
  topology:     vk.PrimitiveTopology,
  polygon_mode: vk.PolygonMode,
  cull_mode:    vk.CullModeFlags,
}

// The geometry pass's vertex shader; its outputs feed every mesh fragment
// shader.
@(private = "file")
MESH_VERT :: #load("shader/gbuffer/vert.spv")

// OPAQUE is drawn by the geometry pass.
PIPELINES := #partial [DrawPipeline]ForwardPipelineDesc {
  .TRANSPARENT = {
    vert = MESH_VERT,
    frag = #load("shader/transparent/frag.spv"),
    sets = MESH_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .FILL,
    cull_mode = {.BACK},
  },
  .WIREFRAME = {
    vert = MESH_VERT,
    frag = #load("shader/wireframe/frag.spv"),
    sets = MESH_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .LINE,
  },
  .RANDOM_COLOR = {
    vert = MESH_VERT,
    frag = #load("shader/random_color/frag.spv"),
    sets = MESH_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .FILL,
    cull_mode = {.BACK},
  },
  .SPRITE = {
    vert = #load("shader/sprite/vert.spv"),
    frag = #load("shader/sprite/frag.spv"),
    sets = SPRITE_SETS,
    topology = .TRIANGLE_LIST,
    polygon_mode = .FILL,
  },
}

ForwardRenderer :: struct {
  pipeline_layouts: [DrawPipeline]vk.PipelineLayout,
  pipelines:        [DrawPipeline]vk.Pipeline,
}

ForwardPushConstant :: struct {
  camera_index: u32,
}

forward_init :: proc(r: ^Manager) -> vk.Result {
  self := &r.internal.forward
  gctx := &r.gctx
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ALPHA}
  for desc, pipe in PIPELINES {
    if pipe == .OPAQUE do continue
    self.pipeline_layouts[pipe] = create_scene_pipeline_layout(
      r,
      desc.sets,
      {stageFlags = {.VERTEX, .FRAGMENT}, size = size_of(ForwardPushConstant)},
    ) or_return
    self.pipelines[pipe] = gpu.create_graphics_pipeline(
      gctx,
      {
        vert = desc.vert,
        frag = desc.frag,
        specialization = &SHADER_SPEC_CONSTANTS,
        vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
        vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
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

forward_shutdown :: proc(self: ^ForwardRenderer, gctx: ^gpu.GPUContext) {
  for pipe in DrawPipeline {
    vk.DestroyPipeline(gctx.device, self.pipelines[pipe], nil)
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layouts[pipe], nil)
  }
  self^ = {}
}

// Forward pipelines in draw order.
@(private = "file")
FORWARD_ORDER := [?]DrawPipeline{.TRANSPARENT, .WIREFRAME, .RANDOM_COLOR, .SPRITE}

// Draw every forward pipeline's list from the camera's draw buffers over the
// lit image, in one render scope, depth-tested against the G-buffer depth.
forward_record :: proc(r: ^Manager, frame_index: u32, cam_index: u32, cam: ^Camera) {
  self := &r.internal.forward
  cmd := r.internal.command_buffers[frame_index]
  color_texture := camera_image(r, cam, .FINAL_IMAGE, frame_index)
  depth_texture := camera_image(r, cam, .DEPTH, frame_index)
  // The barrier goes before the scope: Vulkan disallows vkCmdPipelineBarrier
  // inside a dynamic rendering instance.
  gpu.memory_barrier(
    cmd,
    {.SHADER_READ, .COLOR_ATTACHMENT_WRITE},
    {
      .DEPTH_STENCIL_ATTACHMENT_READ,
      .DEPTH_STENCIL_ATTACHMENT_WRITE,
      .COLOR_ATTACHMENT_READ,
      .COLOR_ATTACHMENT_WRITE,
    },
    {.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
    {.EARLY_FRAGMENT_TESTS, .COLOR_ATTACHMENT_OUTPUT},
  )
  gpu.begin_rendering(
    cmd,
    depth_texture.extent,
    gpu.create_depth_attachment(depth_texture.view, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture.view, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(cmd, depth_texture.extent)
  push_constants := ForwardPushConstant {
    camera_index = cam_index,
  }
  draw_buffer := cam.draws.commands[frame_index].buffer
  count_buffer := cam.draws.count[frame_index].buffer
  for pipe in FORWARD_ORDER {
    layout := self.pipeline_layouts[pipe]
    bind_scene(r, cmd, frame_index, self.pipelines[pipe], layout, PIPELINES[pipe].sets)
    vk.CmdPushConstants(
      cmd,
      layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(ForwardPushConstant),
      &push_constants,
    )
    vk.CmdDrawIndexedIndirectCount(
      cmd,
      draw_buffer,
      vk.DeviceSize(int(pipe) * MAX_NODES_IN_SCENE * size_of(vk.DrawIndexedIndirectCommand)),
      count_buffer,
      vk.DeviceSize(int(pipe) * size_of(u32)),
      MAX_NODES_IN_SCENE,
      u32(size_of(vk.DrawIndexedIndirectCommand)),
    )
  }
  vk.CmdEndRendering(cmd)
  // Make depth writes visible to shader sampling (e.g. depth pyramid build
  // at start of next frame).
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER, .FRAGMENT_SHADER},
  )
}
