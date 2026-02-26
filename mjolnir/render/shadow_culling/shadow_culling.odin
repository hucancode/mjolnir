package shadow_culling

import "../../gpu"
import d "../data"
import vk "vendor:vulkan"

SHADER_SHADOW_CULLING :: #load("../../shader/shadow/cull.spv")

CullPushConstants :: struct {
  shadow_index:  u32,
  node_count:    u32,
  max_draws:     u32,
  include_flags: d.NodeFlagSet,
  exclude_flags: d.NodeFlagSet,
}

System :: struct {
  node_count:       u32,
  max_draws:        u32,
  descriptor_layout: vk.DescriptorSetLayout,
  pipeline_layout:  vk.PipelineLayout,
  pipeline:         vk.Pipeline,
}

init :: proc(self: ^System, gctx: ^gpu.GPUContext) -> (ret: vk.Result) {
  self.max_draws = d.MAX_NODES_IN_SCENE
  self.descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(gctx.device, self.descriptor_layout, nil)
    self.descriptor_layout = 0
  }
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(CullPushConstants),
    },
    self.descriptor_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
    self.pipeline_layout = 0
  }
  shader := gpu.create_shader_module(gctx.device, SHADER_SHADOW_CULLING) or_return
  defer vk.DestroyShaderModule(gctx.device, shader, nil)
  self.pipeline = gpu.create_compute_pipeline(gctx, shader, self.pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.pipeline, nil)
    self.pipeline = 0
  }
  return .SUCCESS
}

shutdown :: proc(self: ^System, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.descriptor_layout, nil)
}

shadow_culling :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  shadow_index: u32,
  shadow: ^d.ShadowMap,
  frame_index: u32,
) {
  include_flags: d.NodeFlagSet = {.VISIBLE}
  exclude_flags: d.NodeFlagSet = {
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
    .MATERIAL_RANDOM_COLOR,
    .MATERIAL_LINE_STRIP,
  }
  dispatch_x := (self.node_count + 63) / 64
  vk.CmdFillBuffer(
    command_buffer,
    shadow.draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(shadow.draw_count[frame_index].bytes_count),
    0,
  )
  gpu.buffer_barrier(
    command_buffer,
    shadow.draw_count[frame_index].buffer,
    vk.DeviceSize(shadow.draw_count[frame_index].bytes_count),
    {.TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.TRANSFER},
    {.COMPUTE_SHADER},
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    shadow.descriptor_sets[frame_index],
  )
  push := CullPushConstants {
    shadow_index  = shadow_index,
    node_count    = self.node_count,
    max_draws     = self.max_draws,
    include_flags = include_flags,
    exclude_flags = exclude_flags,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.COMPUTE},
    0,
    size_of(push),
    &push,
  )
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
}
