package particles_compute

import "../../gpu"
import d "../data"
import rg "../graph"
import "core:log"
import vk "vendor:vulkan"

MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256

SHADER_EMITTER_COMP :: #load("../../shader/particle/emitter.spv")
SHADER_PARTICLE_COMP :: #load("../../shader/particle/compute.spv")
SHADER_PARTICLE_COMPACT_COMP :: #load("../../shader/particle/compact.spv")

Particle :: d.Particle

ParticleSystemParams :: struct {
  particle_count:   u32,
  emitter_count:    u32,
  forcefield_count: u32,
  delta_time:       f32,
}

Renderer :: struct {
  params_buffer:                      gpu.MutableBuffer(ParticleSystemParams),
  particle_count_buffer:              gpu.MutableBuffer(u32),
  node_data_descriptor_set:           vk.DescriptorSet,
  emitter_descriptor_set_layout:      vk.DescriptorSetLayout,
  emitter_descriptor_set:             vk.DescriptorSet,
  emitter_pipeline_layout:            vk.PipelineLayout,
  emitter_pipeline:                   vk.Pipeline,
  emitter_bindless_descriptor_set:    vk.DescriptorSet,
  compute_descriptor_set_layout:      vk.DescriptorSetLayout,
  compute_descriptor_set:             vk.DescriptorSet,
  compute_pipeline_layout:            vk.PipelineLayout,
  compute_pipeline:                   vk.Pipeline,
  forcefield_bindless_descriptor_set: vk.DescriptorSet,
  compact_descriptor_set_layout:      vk.DescriptorSetLayout,
  compact_descriptor_set:             vk.DescriptorSet,
  compact_pipeline_layout:            vk.PipelineLayout,
  compact_pipeline:                   vk.Pipeline,
}

simulate :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  node_data_set: vk.DescriptorSet,
  particle_buffer: vk.Buffer,
  compact_particle_buffer: vk.Buffer,
  draw_command_buffer: vk.Buffer,
  particle_buffer_size: vk.DeviceSize,
) {
  params_ptr := gpu.get(&self.params_buffer)
  counter_ptr := gpu.get(&self.particle_count_buffer)
  params_ptr.particle_count = counter_ptr^
  counter_ptr^ = 0

  gpu.bind_compute_pipeline(
    command_buffer,
    self.emitter_pipeline,
    self.emitter_pipeline_layout,
    self.emitter_bindless_descriptor_set,
    self.emitter_descriptor_set,
    node_data_set,
  )
  // One thread per emitter (local_size_x = 64)
  vk.CmdDispatch(command_buffer, u32(d.MAX_EMITTERS + 63) / 64, 1, 1)

  // Barrier to ensure emission is complete before compaction
  gpu.memory_barrier(
    command_buffer,
    {.SHADER_WRITE},
    {.SHADER_READ},
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
  )

  compact(self, command_buffer)

  // Memory barrier before simulation
  gpu.memory_barrier(
    command_buffer,
    {.SHADER_WRITE},
    {.SHADER_READ},
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
  )

  gpu.bind_compute_pipeline(
    command_buffer,
    self.compute_pipeline,
    self.compute_pipeline_layout,
    self.compute_descriptor_set,
    self.forcefield_bindless_descriptor_set,
    node_data_set,
  )
  vk.CmdDispatch(
    command_buffer,
    u32(MAX_PARTICLES + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH,
    1,
    1,
  )

  // Memory barrier before copying back
  gpu.memory_barrier(
    command_buffer,
    {.SHADER_WRITE},
    {.TRANSFER_READ},
    {.COMPUTE_SHADER},
    {.TRANSFER},
  )

  // Copy simulated particles back to main buffer
  vk.CmdCopyBuffer(
    command_buffer,
    compact_particle_buffer,
    particle_buffer,
    1,
    &vk.BufferCopy{size = particle_buffer_size},
  )

  // Final barrier for rendering
  gpu.memory_barrier(
    command_buffer,
    {.TRANSFER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.TRANSFER},
    {.DRAW_INDIRECT},
  )
}

compact :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  gpu.bind_compute_pipeline(
    command_buffer,
    self.compact_pipeline,
    self.compact_pipeline_layout,
    self.compact_descriptor_set,
  )
  vk.CmdDispatch(
    command_buffer,
    u32(MAX_PARTICLES + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH,
    1,
    1,
  )
}

Blackboard :: struct {
  particle_buffer:     rg.Buffer,
  compact_buffer:      rg.Buffer,
  draw_command_buffer: rg.Buffer,
}

particle_simulation_pass_deps_from_context :: proc(
  pass_ctx: ^rg.PassContext,
) -> Blackboard {
  return Blackboard {
    particle_buffer = rg.get_buffer(pass_ctx, .PARTICLE_BUFFER),
    compact_buffer = rg.get_buffer(pass_ctx, .COMPACT_PARTICLE_BUFFER),
    draw_command_buffer = rg.get_buffer(pass_ctx, .DRAW_COMMAND_BUFFER),
  }
}

particle_simulation_execute :: proc(
  self: ^Renderer,
  pass_ctx: ^rg.PassContext,
  deps: Blackboard,
) {

  particle_buffer := deps.particle_buffer
  compact_buffer := deps.compact_buffer
  draw_command_buffer := deps.draw_command_buffer

  simulate(
    self,
    pass_ctx.cmd,
    self.node_data_descriptor_set,
    particle_buffer.buffer,
    compact_buffer.buffer,
    draw_command_buffer.buffer,
    particle_buffer.size,
  )
}

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  emitter_descriptor_set: vk.DescriptorSet,
  forcefield_descriptor_set: vk.DescriptorSet,
  node_data_descriptor_set: vk.DescriptorSet,
  particle_buffer: ^gpu.MutableBuffer(Particle),
  compact_particle_buffer: ^gpu.MutableBuffer(Particle),
  draw_command_buffer: ^gpu.MutableBuffer(vk.DrawIndirectCommand),
) -> (
  ret: vk.Result,
) {
  self.emitter_bindless_descriptor_set = emitter_descriptor_set
  self.forcefield_bindless_descriptor_set = forcefield_descriptor_set
  self.node_data_descriptor_set = node_data_descriptor_set

  self.params_buffer = gpu.create_mutable_buffer(
    gctx,
    ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.params_buffer)
  }

  self.particle_count_buffer = gpu.create_mutable_buffer(
    gctx,
    u32,
    1,
    {.STORAGE_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_count_buffer)
  }

  self.emitter_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.emitter_descriptor_set_layout,
    {.STORAGE_BUFFER, gpu.buffer_info(particle_buffer)},
    {.STORAGE_BUFFER, gpu.buffer_info(&self.particle_count_buffer)},
    {.UNIFORM_BUFFER, gpu.buffer_info(&self.params_buffer)},
  ) or_return

  self.compute_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.compute_descriptor_set_layout,
    {type = .UNIFORM_BUFFER, info = gpu.buffer_info(&self.params_buffer)},
    {type = .STORAGE_BUFFER, info = gpu.buffer_info(compact_particle_buffer)},
    {
      type = .STORAGE_BUFFER,
      info = gpu.buffer_info(&self.particle_count_buffer),
    },
  ) or_return

  self.compact_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.compact_descriptor_set_layout,
    {type = .STORAGE_BUFFER, info = gpu.buffer_info(particle_buffer)},
    {type = .STORAGE_BUFFER, info = gpu.buffer_info(compact_particle_buffer)},
    {type = .STORAGE_BUFFER, info = gpu.buffer_info(draw_command_buffer)},
    {
      type = .STORAGE_BUFFER,
      info = gpu.buffer_info(&self.particle_count_buffer),
    },
  ) or_return

  return .SUCCESS
}

teardown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  gpu.mutable_buffer_destroy(gctx.device, &self.params_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_count_buffer)
  self.emitter_descriptor_set = 0
  self.compute_descriptor_set = 0
  self.compact_descriptor_set = 0
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.compute_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.compute_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.compute_descriptor_set_layout,
    nil,
  )
  vk.DestroyPipeline(gctx.device, self.emitter_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.emitter_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.emitter_descriptor_set_layout,
    nil,
  )
  vk.DestroyPipeline(gctx.device, self.compact_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.compact_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.compact_descriptor_set_layout,
    nil,
  )
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  emitter_set_layout: vk.DescriptorSetLayout,
  forcefield_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debugf("Initializing particle compute renderer")

  create_emitter_pipeline(
    gctx,
    self,
    emitter_set_layout,
    node_data_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.emitter_descriptor_set_layout,
      nil,
    )
    vk.DestroyPipelineLayout(gctx.device, self.emitter_pipeline_layout, nil)
    vk.DestroyPipeline(gctx.device, self.emitter_pipeline, nil)
  }

  create_compact_pipeline(gctx, self) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.compact_descriptor_set_layout,
      nil,
    )
    vk.DestroyPipelineLayout(gctx.device, self.compact_pipeline_layout, nil)
    vk.DestroyPipeline(gctx.device, self.compact_pipeline, nil)
  }

  create_compute_pipeline(
    gctx,
    self,
    forcefield_set_layout,
    node_data_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.compute_descriptor_set_layout,
      nil,
    )
    vk.DestroyPipelineLayout(gctx.device, self.compute_pipeline_layout, nil)
    vk.DestroyPipeline(gctx.device, self.compute_pipeline, nil)
  }

  return .SUCCESS
}

create_emitter_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  emitter_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.emitter_descriptor_set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.UNIFORM_BUFFER, {.COMPUTE}},
  ) or_return

  self.emitter_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    nil,
    emitter_set_layout,
    self.emitter_descriptor_set_layout,
    node_data_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.emitter_pipeline_layout, nil)
  }

  emitter_shader_module := gpu.create_shader_module(
    gctx.device,
    SHADER_EMITTER_COMP,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, emitter_shader_module, nil)

  emitter_pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = emitter_shader_module,
      pName = "main",
    },
    layout = self.emitter_pipeline_layout,
  }

  vk.CreateComputePipelines(
    gctx.device,
    0,
    1,
    &emitter_pipeline_info,
    nil,
    &self.emitter_pipeline,
  ) or_return

  return .SUCCESS
}

create_compute_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  forcefield_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.compute_descriptor_set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.UNIFORM_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.compute_descriptor_set_layout,
      nil,
    )
  }

  self.compute_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    nil,
    self.compute_descriptor_set_layout,
    forcefield_set_layout,
    node_data_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.compute_pipeline_layout, nil)
  }

  compute_shader_module := gpu.create_shader_module(
    gctx.device,
    SHADER_PARTICLE_COMP,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, compute_shader_module, nil)

  compute_pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = compute_shader_module,
      pName = "main",
    },
    layout = self.compute_pipeline_layout,
  }

  vk.CreateComputePipelines(
    gctx.device,
    0,
    1,
    &compute_pipeline_info,
    nil,
    &self.compute_pipeline,
  ) or_return

  return .SUCCESS
}

create_compact_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
) -> (
  ret: vk.Result,
) {
  self.compact_descriptor_set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.compact_descriptor_set_layout,
      nil,
    )
  }

  self.compact_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    nil,
    self.compact_descriptor_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.compact_pipeline_layout, nil)
  }

  compact_shader_module := gpu.create_shader_module(
    gctx.device,
    SHADER_PARTICLE_COMPACT_COMP,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, compact_shader_module, nil)

  compact_pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = compact_shader_module,
      pName = "main",
    },
    layout = self.compact_pipeline_layout,
  }

  vk.CreateComputePipelines(
    gctx.device,
    0,
    1,
    &compact_pipeline_info,
    nil,
    &self.compact_pipeline,
  ) or_return

  return .SUCCESS
}
