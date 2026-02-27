package shadow_culling

import "../../gpu"
import d "../data"
import vk "vendor:vulkan"

SHADER_SHADOW_CULLING :: #load("../../shader/shadow/cull.spv")

CullPushConstants :: struct {
  frustum_planes: [6][4]f32,
  node_count:     u32,
  max_draws:      u32,
  include_flags:  d.NodeFlagSet,
  exclude_flags:  d.NodeFlagSet,
}
// Total: 112 bytes

System :: struct {
  node_count:        u32,
  max_draws:         u32,
  descriptor_layout: vk.DescriptorSetLayout,
  pipeline_layout:   vk.PipelineLayout,
  pipeline:          vk.Pipeline,
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
  shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SHADOW_CULLING,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, shader, nil)
  self.pipeline = gpu.create_compute_pipeline(
    gctx,
    shader,
    self.pipeline_layout,
  ) or_return
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

execute :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  frustum_planes: [6][4]f32,
  shadow_draw_count_buffer: vk.Buffer,
  shadow_draw_count_ds: vk.DescriptorSet,
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
    shadow_draw_count_buffer,
    0,
    vk.DeviceSize(size_of(u32)),
    0,
  )
  gpu.buffer_barrier(
    command_buffer,
    shadow_draw_count_buffer,
    vk.DeviceSize(size_of(u32)),
    {.TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.TRANSFER},
    {.COMPUTE_SHADER},
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    shadow_draw_count_ds,
  )
  push := CullPushConstants {
    frustum_planes = frustum_planes,
    node_count     = self.node_count,
    max_draws      = self.max_draws,
    include_flags  = include_flags,
    exclude_flags  = exclude_flags,
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
