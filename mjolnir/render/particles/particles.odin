package particles

import cont "../../containers"
import "../../gpu"
import "../../resources"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256
SHADER_EMITTER_COMP :: #load("../../shader/particle/emitter.spv")
SHADER_PARTICLE_COMP :: #load("../../shader/particle/compute.spv")
SHADER_PARTICLE_COMPACT_COMP :: #load("../../shader/particle/compact.spv")
SHADER_PARTICLE_VERT := #load("../../shader/particle/vert.spv")
SHADER_PARTICLE_FRAG := #load("../../shader/particle/frag.spv")
TEXTURE_BLACK_CIRCLE :: #load("../../assets/black-circle.png")

Particle :: struct {
  position:      [3]f32,
  size:          f32,
  velocity:      [3]f32,
  size_end:      f32,
  color_start:   [4]f32,
  color_end:     [4]f32,
  color:         [4]f32,
  life:          f32,
  max_life:      f32,
  weight:        f32,
  texture_index: u32,
}

ParticleSystemParams :: struct {
  particle_count:   u32,
  emitter_count:    u32,
  forcefield_count: u32,
  delta_time:       f32,
}

Renderer :: struct {
  // Compute pipeline
  params_buffer:                      gpu.MutableBuffer(ParticleSystemParams),
  particle_buffer:                    gpu.MutableBuffer(Particle),
  compute_descriptor_set_layout:      vk.DescriptorSetLayout,
  compute_descriptor_set:             vk.DescriptorSet,
  compute_pipeline_layout:            vk.PipelineLayout,
  compute_pipeline:                   vk.Pipeline,
  forcefield_bindless_descriptor_set: vk.DescriptorSet,
  // Emitter pipeline
  emitter_pipeline_layout:            vk.PipelineLayout,
  emitter_pipeline:                   vk.Pipeline,
  emitter_descriptor_set_layout:      vk.DescriptorSetLayout,
  emitter_descriptor_set:             vk.DescriptorSet,
  emitter_bindless_descriptor_set:    vk.DescriptorSet,
  particle_count_buffer:              gpu.MutableBuffer(u32),
  // Compaction pipeline
  compact_particle_buffer:            gpu.MutableBuffer(Particle),
  draw_command_buffer:                gpu.MutableBuffer(
    vk.DrawIndirectCommand,
  ),
  compact_descriptor_set_layout:      vk.DescriptorSetLayout,
  compact_descriptor_set:             vk.DescriptorSet,
  compact_pipeline_layout:            vk.PipelineLayout,
  compact_pipeline:                   vk.Pipeline,
  // Render pipeline
  render_pipeline_layout:             vk.PipelineLayout,
  render_pipeline:                    vk.Pipeline,
  default_texture_index:              u32,
}

simulate :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  world_matrix_set: vk.DescriptorSet,
  rm: ^resources.Manager,
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
    world_matrix_set,
  )
  // One thread per emitter (local_size_x = 64)
  vk.CmdDispatch(command_buffer, u32(resources.MAX_EMITTERS + 63) / 64, 1, 1)
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
  // GPU handles the count internally
  gpu.bind_compute_pipeline(
    command_buffer,
    self.compute_pipeline,
    self.compute_pipeline_layout,
    self.compute_descriptor_set,
    self.forcefield_bindless_descriptor_set,
    rm.world_matrix_buffer.descriptor_set,
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
    self.compact_particle_buffer.buffer,
    self.particle_buffer.buffer,
    1,
    &vk.BufferCopy{size = vk.DeviceSize(self.particle_buffer.bytes_count)},
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
  vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
  gpu.mutable_buffer_destroy(gctx.device, &self.params_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.compact_particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.draw_command_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_count_buffer)
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> (
  ret: vk.Result,
) {
  log.debugf("Initializing particle renderer")
  self.params_buffer = gpu.create_mutable_buffer(
    gctx,
    ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.params_buffer)
  }
  self.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    Particle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_buffer)
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
  self.emitter_bindless_descriptor_set = rm.emitter_buffer.descriptor_set
  self.forcefield_bindless_descriptor_set = rm.forcefield_buffer.descriptor_set
  create_emitter_pipeline(gctx, self, rm) or_return
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
  create_compute_pipeline(gctx, self, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.compute_descriptor_set_layout,
      nil,
    )
    vk.DestroyPipelineLayout(gctx.device, self.compute_pipeline_layout, nil)
    vk.DestroyPipeline(gctx.device, self.compute_pipeline, nil)
  }
  create_render_pipeline(gctx, self, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
    vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
  }
  return .SUCCESS
}

create_emitter_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  rm: ^resources.Manager,
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
    rm.emitter_buffer.set_layout,
    self.emitter_descriptor_set_layout,
    rm.world_matrix_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.emitter_pipeline_layout, nil)
  }
  self.emitter_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.emitter_descriptor_set_layout,
    {.STORAGE_BUFFER, gpu.buffer_info(&self.particle_buffer)},
    {.STORAGE_BUFFER, gpu.buffer_info(&self.particle_count_buffer)},
    {.UNIFORM_BUFFER, gpu.buffer_info(&self.params_buffer)},
  ) or_return
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
  rm: ^resources.Manager,
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
    rm.forcefield_buffer.set_layout,
    rm.world_matrix_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.compute_pipeline_layout, nil)
  }
  self.compute_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.compute_descriptor_set_layout,
    {type = .UNIFORM_BUFFER, info = gpu.buffer_info(&self.params_buffer)},
    {
      type = .STORAGE_BUFFER,
      info = gpu.buffer_info(&self.compact_particle_buffer),
    },
    {
      type = .STORAGE_BUFFER,
      info = gpu.buffer_info(&self.particle_count_buffer),
    },
  ) or_return
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
  self.compact_particle_buffer = gpu.create_mutable_buffer(
    gctx,
    Particle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.compact_particle_buffer)
  }
  self.draw_command_buffer = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndirectCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.draw_command_buffer)
  }
  self.compact_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.compact_descriptor_set_layout,
    {type = .STORAGE_BUFFER, info = gpu.buffer_info(&self.particle_buffer)},
    {
      type = .STORAGE_BUFFER,
      info = gpu.buffer_info(&self.compact_particle_buffer),
    },
    {
      type = .STORAGE_BUFFER,
      info = gpu.buffer_info(&self.draw_command_buffer),
    },
    {
      type = .STORAGE_BUFFER,
      info = gpu.buffer_info(&self.particle_count_buffer),
    },
  ) or_return
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

create_render_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  rm: ^resources.Manager,
) -> (
  ret: vk.Result,
) {
  self.render_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(u32)},
    rm.camera_buffer.set_layout,
    rm.textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
  }
  default_texture_handle := resources.create_texture_from_data(
    gctx,
    rm,
    TEXTURE_BLACK_CIRCLE,
  ) or_return
  defer if ret != .SUCCESS {
    resources.destroy_texture(gctx.device, rm, default_texture_handle)
  }
  self.default_texture_index = default_texture_handle.index
  vertex_binding := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Particle),
    inputRate = .VERTEX,
  }
  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, position)),
    },
    {
      location = 1,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, color)),
    },
    {
      location = 2,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, size)),
    },
    {
      location = 3,
      binding = 0,
      format = .R32_UINT,
      offset = u32(offset_of(Particle, texture_index)),
    },
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_PARTICLE_VERT,
  ) or_return
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_PARTICLE_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.POINT_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    layout              = self.render_pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.render_pipeline,
  ) or_return
  return .SUCCESS
}

begin_pass :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  camera_handle: resources.CameraHandle,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  color_texture := cont.get(
    rm.images_2d,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  if color_texture == nil {
    log.error("Particle renderer missing color attachment")
    return
  }
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  if depth_texture == nil {
    log.error("Particle renderer missing depth attachment")
    return
  }
  extent := camera.extent
  gpu.begin_rendering(
    command_buffer,
    extent.width,
    extent.height,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(command_buffer, extent.width, extent.height)
}

render :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  rm: ^resources.Manager,
  frame_index: u32 = 0,
) {
  // Use indirect draw - GPU handles the count
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.render_pipeline,
    self.render_pipeline_layout,
    rm.camera_buffer.descriptor_sets[frame_index],
    rm.textures_descriptor_set,
  )
  camera_idx := camera_index
  vk.CmdPushConstants(
    command_buffer,
    self.render_pipeline_layout,
    {.VERTEX},
    0,
    size_of(u32),
    &camera_idx,
  )
  offset: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &self.compact_particle_buffer.buffer,
    &offset,
  )
  vk.CmdDrawIndirect(
    command_buffer,
    self.draw_command_buffer.buffer,
    0,
    1,
    size_of(vk.DrawIndirectCommand),
  )
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
