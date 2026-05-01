package shadow_sphere_culling

import "../../gpu"
import vk "vendor:vulkan"

SHADER_SPHERE_CULLING :: #load("../../shader/shadow_spherical/cull.spv")

// include_flags / exclude_flags use the bit layout of render.NodeFlagSet; the
// caller transmutes its NodeFlagSet to u32.
SphereCullPushConstants :: struct {
  light_position: [3]f32,
  sphere_radius:  f32,
  node_count:     u32,
  max_draws:      u32,
  include_flags:  u32,
  exclude_flags:  u32,
}

System :: struct {
  node_count:        u32,
  max_draws:         u32,
  include_flags:     u32,
  exclude_flags:     u32,
  descriptor_layout: vk.DescriptorSetLayout,
  pipeline_layout:   vk.PipelineLayout,
  pipeline:          vk.Pipeline,
}

init :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  max_draws: u32,
  include_flags: u32,
  exclude_flags: u32,
) -> (
  ret: vk.Result,
) {
  self.max_draws = max_draws
  self.include_flags = include_flags
  self.exclude_flags = exclude_flags
  self.descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},  // nodes
    {.STORAGE_BUFFER, {.COMPUTE}},  // meshes
    {.STORAGE_BUFFER, {.COMPUTE}},  // draw_count
    {.STORAGE_BUFFER, {.COMPUTE}},  // draw_commands
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(gctx.device, self.descriptor_layout, nil)
    self.descriptor_layout = 0
  }
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(SphereCullPushConstants),
    },
    self.descriptor_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
    self.pipeline_layout = 0
  }
  shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_CULLING,
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

create_per_light_descriptor :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  node_buffer: vk.DescriptorBufferInfo,
  mesh_buffer: vk.DescriptorBufferInfo,
  draw_count: vk.DescriptorBufferInfo,
  draw_commands: vk.DescriptorBufferInfo,
) -> (
  vk.DescriptorSet,
  vk.Result,
) {
  return gpu.create_descriptor_set(
    gctx,
    &self.descriptor_layout,
    {.STORAGE_BUFFER, node_buffer},
    {.STORAGE_BUFFER, mesh_buffer},
    {.STORAGE_BUFFER, draw_count},
    {.STORAGE_BUFFER, draw_commands},
  )
}

execute :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  light_position: [3]f32,
  sphere_radius: f32,
  shadow_draw_count_buffer: vk.Buffer,
  shadow_draw_count_ds: vk.DescriptorSet,
) {
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
  push := SphereCullPushConstants {
    light_position = light_position,
    sphere_radius  = sphere_radius,
    node_count     = self.node_count,
    max_draws      = self.max_draws,
    include_flags  = self.include_flags,
    exclude_flags  = self.exclude_flags,
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
