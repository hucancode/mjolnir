package mjolnir

import "core:log"
import "geometry"
import vk "vendor:vulkan"

MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256

MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32

Emitter :: struct {
  transform:         matrix[4, 4]f32,
  initial_velocity:  [4]f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  emission_rate:     f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  time_accumulator:  f32,
  size_start:        f32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  texture_index:     u32,
  culling_enabled:   b32,
  padding:           u32,
  aabb_min:          [4]f32, // xyz = min bounds, w = unused
  aabb_max:          [4]f32, // xyz = max bounds, w = unused
}

ForceField :: struct {
  tangent_strength: f32, // 0 = push/pull in straight line, 1 = push/pull in tangent line
  strength:         f32, // positive = attract, negative = repel
  area_of_effect:   f32, // radius
  fade:             f32, // 0..1, linear fade factor
  position:         [4]f32, // world position
}

Particle :: struct {
  position:      [4]f32,
  velocity:      [4]f32,
  color_start:   [4]f32,
  color_end:     [4]f32,
  color:         [4]f32,
  size:          f32,
  size_end:      f32,
  life:          f32,
  max_life:      f32,
  weight:        f32,
  texture_index: u32,
  padding:       [6]u32,
}

ParticleSystemParams :: struct {
  particle_count:   u32,
  emitter_count:    u32,
  forcefield_count: u32,
  delta_time:       f32,
  // Camera frustum planes for culling (6 planes, each has 4 components)
  frustum_planes:   [6][4]f32,
}

// Push constants for particle rendering
ParticlePushConstants :: struct {
  view:       matrix[4, 4]f32,
  projection: matrix[4, 4]f32,
}

// Draw command for indirect rendering
DrawCommand :: struct {
  vertex_count:   u32,
  instance_count: u32,
  first_vertex:   u32,
  first_instance: u32,
}

RendererParticle :: struct {
  // Compute pipeline
  params_buffer:                 DataBuffer(ParticleSystemParams),
  particle_buffer:               DataBuffer(Particle),
  emitter_buffer:                DataBuffer(Emitter),
  force_field_buffer:            DataBuffer(ForceField),
  compute_descriptor_set_layout: vk.DescriptorSetLayout,
  compute_descriptor_set:        vk.DescriptorSet,
  compute_pipeline_layout:       vk.PipelineLayout,
  compute_pipeline:              vk.Pipeline,
  // Emitter pipeline
  emitter_pipeline_layout:       vk.PipelineLayout,
  emitter_pipeline:              vk.Pipeline,
  emitter_descriptor_set_layout: vk.DescriptorSetLayout,
  emitter_descriptor_set:        vk.DescriptorSet,
  particle_counter_buffer:       DataBuffer(u32),
  // Culling pipeline
  emitter_visibility_buffer:     DataBuffer(u32), // One u32 per emitter for visibility
  // Compaction pipeline
  compact_particle_buffer:       DataBuffer(Particle),
  draw_command_buffer:           DataBuffer(DrawCommand),
  compact_descriptor_set_layout: vk.DescriptorSetLayout,
  compact_descriptor_set:        vk.DescriptorSet,
  compact_pipeline_layout:       vk.PipelineLayout,
  compact_pipeline:              vk.Pipeline,
  // Render pipeline
  render_pipeline_layout:        vk.PipelineLayout,
  render_pipeline:               vk.Pipeline,
  default_texture_index:         u32,
}

compute_particles :: proc(
  self: ^RendererParticle,
  command_buffer: vk.CommandBuffer,
  camera: geometry.Camera,
) {
  // --- Update frustum planes for culling ---
  params_ptr := data_buffer_get(&self.params_buffer)
  frustum := geometry.camera_make_frustum(camera)
  for i in 0 ..< 6 {
    params_ptr.frustum_planes[i] = frustum.planes[i]
  }
  // --- GPU Emitter Dispatch ---
  counter_ptr := data_buffer_get(&self.particle_counter_buffer)
  params_ptr.particle_count = counter_ptr^
  // log.debugf("previous frame's particle count %d", counter_ptr^)
  counter_ptr^ = 0
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.emitter_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    self.emitter_pipeline_layout,
    0,
    1,
    &self.emitter_descriptor_set,
    0,
    nil,
  )
  // One thread per emitter (local_size_x = 64)
  vk.CmdDispatch(command_buffer, u32(MAX_EMITTERS + 63) / 64, 1, 1)

  // Barrier to ensure emission is complete before compaction
  barrier_emit := vk.MemoryBarrier {
    sType         = .MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.SHADER_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
    {},
    1,
    &barrier_emit,
    0,
    nil,
    0,
    nil,
  )

  // --- Compact particles first ---
  compact_particles(self, command_buffer)

  // Memory barrier before simulation
  barrier1 := vk.MemoryBarrier {
    sType         = .MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.SHADER_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
    {},
    1,
    &barrier1,
    0,
    nil,
    0,
    nil,
  )
  // --- Particle Simulation Dispatch ---
  // GPU handles the count internally - no CPU read needed
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.compute_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    self.compute_pipeline_layout,
    0,
    1,
    &self.compute_descriptor_set,
    0,
    nil,
  )
  vk.CmdDispatch(
    command_buffer,
    u32(MAX_PARTICLES + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH,
    1,
    1,
  )

  // Memory barrier before copying back
  barrier2 := vk.MemoryBarrier {
    sType         = .MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.TRANSFER_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.TRANSFER},
    {},
    1,
    &barrier2,
    0,
    nil,
    0,
    nil,
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
  barrier3 := vk.MemoryBarrier {
    sType         = .MEMORY_BARRIER,
    srcAccessMask = {.TRANSFER_WRITE},
    dstAccessMask = {.VERTEX_ATTRIBUTE_READ, .INDIRECT_COMMAND_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.VERTEX_INPUT, .DRAW_INDIRECT},
    {},
    1,
    &barrier3,
    0,
    nil,
    0,
    nil,
  )
}

compact_particles :: proc(
  self: ^RendererParticle,
  command_buffer: vk.CommandBuffer,
) {
  // Run compaction
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.compact_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    self.compact_pipeline_layout,
    0,
    1,
    &self.compact_descriptor_set,
    0,
    nil,
  )
  vk.CmdDispatch(
    command_buffer,
    u32(MAX_PARTICLES + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH,
    1,
    1,
  )
}

renderer_particle_deinit :: proc(self: ^RendererParticle) {
  vk.DestroyPipeline(g_device, self.compute_pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.compute_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.compute_descriptor_set_layout,
    nil,
  )
  vk.DestroyPipeline(g_device, self.emitter_pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.emitter_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.emitter_descriptor_set_layout,
    nil,
  )
  vk.DestroyPipeline(g_device, self.compact_pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.compact_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.compact_descriptor_set_layout,
    nil,
  )
  vk.DestroyPipeline(g_device, self.render_pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.render_pipeline_layout, nil)
  data_buffer_deinit(&self.params_buffer)
  data_buffer_deinit(&self.particle_buffer)
  data_buffer_deinit(&self.compact_particle_buffer)
  data_buffer_deinit(&self.draw_command_buffer)
  data_buffer_deinit(&self.emitter_buffer)
  data_buffer_deinit(&self.force_field_buffer)
  data_buffer_deinit(&self.particle_counter_buffer)
}

renderer_particle_init :: proc(self: ^RendererParticle) -> vk.Result {
  log.debugf("Initializing particle renderer")
  self.params_buffer = create_host_visible_buffer(
    ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  self.particle_buffer = create_host_visible_buffer(
    Particle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  self.emitter_buffer = create_host_visible_buffer(
    Emitter,
    MAX_EMITTERS,
    {.STORAGE_BUFFER},
  ) or_return
  self.force_field_buffer = create_host_visible_buffer(
    ForceField,
    MAX_FORCE_FIELDS,
    {.STORAGE_BUFFER},
  ) or_return
  // Emitter pipeline buffers
  self.particle_counter_buffer = create_host_visible_buffer(
    u32,
    1,
    {.STORAGE_BUFFER},
  ) or_return
  self.emitter_visibility_buffer = create_host_visible_buffer(
    u32,
    MAX_EMITTERS,
    {.STORAGE_BUFFER},
  ) or_return
  renderer_particle_init_emitter_pipeline(self) or_return
  renderer_particle_init_culling_pipeline(self) or_return
  renderer_particle_init_compact_pipeline(self) or_return
  renderer_particle_init_compute_pipeline(self) or_return
  renderer_particle_init_render_pipeline(self) or_return
  return .SUCCESS
}
renderer_particle_init_emitter_pipeline :: proc(
  self: ^RendererParticle,
) -> vk.Result {
  // --- Emitter pipeline ---
  emitter_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0,
      descriptorType  = .STORAGE_BUFFER, // Particle buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 1,
      descriptorType  = .STORAGE_BUFFER, // Emitter buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 2,
      descriptorType  = .STORAGE_BUFFER, // Particle counter buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 3,
      descriptorType  = .UNIFORM_BUFFER, // Params buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 4,
      descriptorType  = .STORAGE_BUFFER, // Visibility buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(emitter_bindings),
      pBindings = raw_data(emitter_bindings[:]),
    },
    nil,
    &self.emitter_descriptor_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.emitter_descriptor_set_layout,
    },
    &self.emitter_descriptor_set,
  ) or_return
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.emitter_descriptor_set_layout,
    },
    nil,
    &self.emitter_pipeline_layout,
  ) or_return
  emitter_particle_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.particle_buffer.buffer,
    range  = vk.DeviceSize(self.particle_buffer.bytes_count),
  }
  emitter_emitter_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.emitter_buffer.buffer,
    range  = vk.DeviceSize(self.emitter_buffer.bytes_count),
  }
  emitter_counter_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.particle_counter_buffer.buffer,
    range  = vk.DeviceSize(self.particle_counter_buffer.bytes_count),
  }
  emitter_params_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.params_buffer.buffer,
    range  = vk.DeviceSize(self.params_buffer.bytes_count),
  }
  emitter_visibility_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.emitter_visibility_buffer.buffer,
    range  = vk.DeviceSize(self.emitter_visibility_buffer.bytes_count),
  }
  emitter_writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.emitter_descriptor_set,
      dstBinding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &emitter_particle_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.emitter_descriptor_set,
      dstBinding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &emitter_emitter_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.emitter_descriptor_set,
      dstBinding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &emitter_counter_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.emitter_descriptor_set,
      dstBinding = 3,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &emitter_params_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.emitter_descriptor_set,
      dstBinding = 4,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &emitter_visibility_buffer_info,
    },
  }
  vk.UpdateDescriptorSets(
    g_device,
    len(emitter_writes),
    raw_data(emitter_writes[:]),
    0,
    nil,
  )
  emitter_shader_module := create_shader_module(
    #load("shader/particle/emitter.spv"),
  ) or_return
  defer vk.DestroyShaderModule(g_device, emitter_shader_module, nil)
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
    g_device,
    0,
    1,
    &emitter_pipeline_info,
    nil,
    &self.emitter_pipeline,
  ) or_return
  return .SUCCESS
}

renderer_particle_init_culling_pipeline :: proc(
  self: ^RendererParticle,
) -> vk.Result {
  // --- Culling pipeline ---
  culling_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER, // Params buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 1,
      descriptorType  = .STORAGE_BUFFER, // Emitter buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 2,
      descriptorType  = .STORAGE_BUFFER, // Visibility buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }

  culling_params_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.params_buffer.buffer,
    range  = vk.DeviceSize(self.params_buffer.bytes_count),
  }
  culling_emitter_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.emitter_buffer.buffer,
    range  = vk.DeviceSize(self.emitter_buffer.bytes_count),
  }
  culling_visibility_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.emitter_visibility_buffer.buffer,
    range  = vk.DeviceSize(self.emitter_visibility_buffer.bytes_count),
  }

  return .SUCCESS
}

renderer_particle_init_compute_pipeline :: proc(
  self: ^RendererParticle,
) -> vk.Result {
  // --- Compute pipeline (particle simulation) ---
  compute_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(compute_bindings),
      pBindings = raw_data(compute_bindings[:]),
    },
    nil,
    &self.compute_descriptor_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.compute_descriptor_set_layout,
    },
    &self.compute_descriptor_set,
  ) or_return
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.compute_descriptor_set_layout,
    },
    nil,
    &self.compute_pipeline_layout,
  ) or_return
  params_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.params_buffer.buffer,
    range  = vk.DeviceSize(self.params_buffer.bytes_count),
  }
  particle_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.compact_particle_buffer.buffer,
    range  = vk.DeviceSize(self.compact_particle_buffer.bytes_count),
  }
  force_field_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.force_field_buffer.buffer,
    range  = vk.DeviceSize(self.force_field_buffer.bytes_count),
  }
  count_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.particle_counter_buffer.buffer,
    range  = vk.DeviceSize(self.particle_counter_buffer.bytes_count),
  }
  compute_writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compute_descriptor_set,
      dstBinding = 0,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &params_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compute_descriptor_set,
      dstBinding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &particle_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compute_descriptor_set,
      dstBinding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &force_field_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compute_descriptor_set,
      dstBinding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &count_buffer_info,
    },
  }
  vk.UpdateDescriptorSets(
    g_device,
    len(compute_writes),
    raw_data(compute_writes[:]),
    0,
    nil,
  )
  compute_shader_module := create_shader_module(
    #load("shader/particle/compute.spv"),
  ) or_return
  defer vk.DestroyShaderModule(g_device, compute_shader_module, nil)
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
    g_device,
    0,
    1,
    &compute_pipeline_info,
    nil,
    &self.compute_pipeline,
  ) or_return
  return .SUCCESS
}

renderer_particle_init_compact_pipeline :: proc(
  self: ^RendererParticle,
) -> vk.Result {
  // --- Compaction pipeline ---
  compact_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(compact_bindings),
      pBindings = raw_data(compact_bindings[:]),
    },
    nil,
    &self.compact_descriptor_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.compact_descriptor_set_layout,
    },
    &self.compact_descriptor_set,
  ) or_return
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.compact_descriptor_set_layout,
    },
    nil,
    &self.compact_pipeline_layout,
  ) or_return
  self.compact_particle_buffer = create_host_visible_buffer(
    Particle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  self.draw_command_buffer = create_host_visible_buffer(
    DrawCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  compact_source_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.particle_buffer.buffer,
    range  = vk.DeviceSize(self.particle_buffer.bytes_count),
  }
  compact_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.compact_particle_buffer.buffer,
    range  = vk.DeviceSize(self.compact_particle_buffer.bytes_count),
  }
  draw_cmd_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.draw_command_buffer.buffer,
    range  = vk.DeviceSize(self.draw_command_buffer.bytes_count),
  }
  count_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.particle_counter_buffer.buffer,
    range  = vk.DeviceSize(self.particle_counter_buffer.bytes_count),
  }
  compact_writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compact_descriptor_set,
      dstBinding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &compact_source_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compact_descriptor_set,
      dstBinding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &compact_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compact_descriptor_set,
      dstBinding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &draw_cmd_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compact_descriptor_set,
      dstBinding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &count_buffer_info,
    },
  }
  vk.UpdateDescriptorSets(
    g_device,
    len(compact_writes),
    raw_data(compact_writes[:]),
    0,
    nil,
  )
  compact_shader_module := create_shader_module(
    #load("shader/particle/compact.spv"),
  ) or_return
  defer vk.DestroyShaderModule(g_device, compact_shader_module, nil)
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
    g_device,
    0,
    1,
    &compact_pipeline_info,
    nil,
    &self.compact_pipeline,
  ) or_return
  return .SUCCESS
}

renderer_particle_init_render_pipeline :: proc(
  self: ^RendererParticle,
) -> vk.Result {
  descriptor_set_layouts := [?]vk.DescriptorSetLayout {
    g_camera_descriptor_set_layout, // set = 0 for camera
    g_textures_set_layout, // set = 1 for textures
  }
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(descriptor_set_layouts),
      pSetLayouts = raw_data(descriptor_set_layouts[:]),
    },
    nil,
    &self.render_pipeline_layout,
  ) or_return
  default_texture_handle, _ := create_texture_from_data(
    #load("assets/black-circle.png"),
  ) or_return
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
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .POINT_LIST,
  }
  rasterization := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable        = false,
    rasterizerDiscardEnable = false,
    polygonMode             = .FILL,
    lineWidth               = 1.0,
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
    alphaBlendOp        = .ADD,
    colorWriteMask      = {.R, .G, .B, .A},
  }
  blend_state := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  multisample := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  vert_shader_code := #load("shader/particle/vert.spv")
  frag_shader_code := #load("shader/particle/frag.spv")
  vert_module := create_shader_module(vert_shader_code) or_return
  frag_module := create_shader_module(frag_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
    },
  }
  color_formats := [?]vk.Format{.B8G8R8A8_SRGB}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = .D32_SFLOAT,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS_OR_EQUAL,
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterization,
    pMultisampleState   = &multisample,
    pColorBlendState    = &blend_state,
    pDynamicState       = &dynamic_state,
    layout              = self.render_pipeline_layout,
    pNext               = &rendering_info,
    pDepthStencilState  = &depth_stencil,
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.render_pipeline,
  ) or_return
  return .SUCCESS
}

renderer_particle_begin :: proc(
  self: ^RendererParticle,
  command_buffer: vk.CommandBuffer,
  render_target: RenderTarget,
) {
  // Memory barrier to ensure compute results are visible before rendering
  barrier := vk.BufferMemoryBarrier {
    sType               = .BUFFER_MEMORY_BARRIER,
    srcAccessMask       = {.SHADER_WRITE},
    dstAccessMask       = {.VERTEX_ATTRIBUTE_READ},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer              = self.particle_buffer.buffer,
    size                = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.VERTEX_INPUT},
    {},
    0,
    nil, // memoryBarrierCount, pMemoryBarriers
    1,
    &barrier, // bufferMemoryBarrierCount, pBufferMemoryBarriers
    0,
    nil, // imageMemoryBarrierCount, pImageMemoryBarriers
  )
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = render_target.final,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD, // preserve previous contents
    storeOp     = .STORE,
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = render_target.depth,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = render_target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(render_target.extent.height),
    width    = f32(render_target.extent.width),
    height   = -f32(render_target.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = render_target.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

renderer_particle_render :: proc(
  self: ^RendererParticle,
  command_buffer: vk.CommandBuffer,
) {
  // Use indirect draw - GPU handles the count
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.render_pipeline)
  descriptor_sets := [?]vk.DescriptorSet {
    g_camera_descriptor_sets[g_frame_index], // set 0 (camera)
    g_textures_descriptor_set, // set 1 (textures)
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.render_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
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
    size_of(DrawCommand),
  )
}

renderer_particle_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

get_particle_render_stats :: proc(
  self: ^RendererParticle,
) -> (
  rendered: u32,
  total_allocated: u32,
) {
  count := data_buffer_get(&self.particle_counter_buffer)
  return count^, MAX_PARTICLES
}

// Helper function to create an emitter with AABB culling bounds
create_emitter_with_aabb :: proc(
  transform: matrix[4, 4]f32,
  aabb_min: [3]f32,
  aabb_max: [3]f32,
  enable_culling: bool = true,
) -> Emitter {
  return Emitter {
    transform         = transform,
    aabb_min          = {aabb_min.x, aabb_min.y, aabb_min.z, 0.0},
    aabb_max          = {aabb_max.x, aabb_max.y, aabb_max.z, 0.0},
    culling_enabled   = b32(enable_culling),
    // Default values - user should set these
    emission_rate     = 10.0,
    particle_lifetime = 5.0,
    position_spread   = 1.0,
    velocity_spread   = 0.1,
    size_start        = 1.0,
    size_end          = 0.1,
    weight            = 1.0,
    weight_spread     = 0.0,
    texture_index     = 0,
    initial_velocity  = {0.0, 1.0, 0.0, 0.0},
    color_start       = {1.0, 1.0, 1.0, 1.0},
    color_end         = {0.5, 0.5, 0.5, 0.0},
    time_accumulator  = 0.0,
  }
}

// Helper function to update emitter AABB bounds
update_emitter_aabb :: proc(
  emitter: ^Emitter,
  aabb_min: [3]f32,
  aabb_max: [3]f32,
) {
  emitter.aabb_min = {aabb_min.x, aabb_min.y, aabb_min.z, 0.0}
  emitter.aabb_max = {aabb_max.x, aabb_max.y, aabb_max.z, 0.0}
}

// Helper function to enable/disable culling for an emitter
set_emitter_culling :: proc(emitter: ^Emitter, enable: bool) {
  emitter.culling_enabled = b32(enable)
}
