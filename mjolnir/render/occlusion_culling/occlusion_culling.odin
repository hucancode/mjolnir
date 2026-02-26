package occlusion_culling

import alg "../../algebra"
import "../../gpu"
import cam "../camera"
import d "../data"
import rd "../data"
import vk "vendor:vulkan"

SHADER_CULLING :: #load("../../shader/occlusion_culling/cull.spv")

VisibilityPushConstants :: struct {
  camera_index:      u32,
  node_count:        u32,
  max_draws:         u32,
  pyramid_width:     f32,
  pyramid_height:    f32,
  depth_bias:        f32,
  occlusion_enabled: u32,
}

CullingStats :: struct {
  opaque_draw_count: u32,
  camera_index:      u32,
  frame_index:       u32,
}

System :: struct {
  cull_layout:            vk.PipelineLayout,
  cull_pipeline:          vk.Pipeline,
  depth_descriptor_layout: vk.DescriptorSetLayout,
  max_draws:              u32,
  node_count:             u32,
  depth_bias:             f32,
  stats_enabled:          bool,
}

init :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  self.max_draws = d.MAX_NODES_IN_SCENE
  self.depth_bias = 0.0001
  self.depth_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.depth_descriptor_layout,
      nil,
    )
    self.depth_descriptor_layout = 0
  }
  self.cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(VisibilityPushConstants),
    },
    self.depth_descriptor_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.cull_layout, nil)
    self.cull_layout = 0
  }
  shader := gpu.create_shader_module(gctx.device, SHADER_CULLING) or_return
  defer vk.DestroyShaderModule(gctx.device, shader, nil)
  self.cull_pipeline = gpu.create_compute_pipeline(
    gctx,
    shader,
    self.cull_layout,
  ) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^System, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  self.cull_pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.cull_layout, nil)
  self.cull_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.depth_descriptor_layout,
    nil,
  )
  self.depth_descriptor_layout = 0
}

stats :: proc(
  self: ^System,
  camera: ^cam.Camera,
  camera_index: u32,
  frame_index: u32,
) -> CullingStats {
  stats := CullingStats {
    camera_index = camera_index,
    frame_index  = frame_index,
  }
  if camera.opaque_draw_count[frame_index].mapped != nil {
    stats.opaque_draw_count = camera.opaque_draw_count[frame_index].mapped[0]
  }
  _ = self
  return stats
}

perform_culling :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  camera: ^cam.Camera,
  camera_index: u32,
  frame_index: u32,
) {
  if self.node_count == 0 do return
  vk.CmdFillBuffer(
    command_buffer,
    camera.opaque_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.opaque_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.transparent_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.transparent_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.sprite_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.sprite_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.wireframe_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.wireframe_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.random_color_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.random_color_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.line_strip_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.line_strip_draw_count[frame_index].bytes_count),
    0,
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.cull_pipeline,
    self.cull_layout,
    camera.descriptor_set[frame_index],
  )
  prev_frame := alg.prev(frame_index, d.FRAMES_IN_FLIGHT)
  push_constants := VisibilityPushConstants {
    camera_index      = camera_index,
    node_count        = self.node_count,
    max_draws         = self.max_draws,
    pyramid_width     = f32(camera.depth_pyramid[prev_frame].width),
    pyramid_height    = f32(camera.depth_pyramid[prev_frame].height),
    depth_bias        = self.depth_bias,
    occlusion_enabled = 1,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )
  dispatch_x := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
}
