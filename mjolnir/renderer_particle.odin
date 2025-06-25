package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "geometry"
import vk "vendor:vulkan"

MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256

MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32

// Shared Emitter struct for use in both scene and renderer_particle
Emitter :: struct {
  transform:         linalg.Matrix4f32,
  emission_rate:     f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  time_accumulator:  f32,
  initial_velocity:  linalg.Vector4f32,
  color_start:       linalg.Vector4f32,
  color_end:         linalg.Vector4f32,
  size_start:        f32,
  size_end:          f32,
  enabled:           b32,
  weight:            f32,
  weight_spread:     f32,
  padding:           [3]f32,
}

// Shared ForceField struct for use in both scene and renderer_particle
ForceFieldBehavior :: enum (u32) {
  ATTRACT,
  REPEL,
  ORBIT,
}

ForceField :: struct {
  behavior:       ForceFieldBehavior,
  strength:       f32,
  area_of_effect: f32, // radius
  fade:           f32, // 0..1, linear fade factor
  position:       linalg.Vector4f32, // world position
}

Particle :: struct {
  position:    linalg.Vector4f32,
  velocity:    linalg.Vector4f32,
  color_start: linalg.Vector4f32,
  color_end:   linalg.Vector4f32,
  color:       linalg.Vector4f32,
  size:        f32,
  size_end:    f32,
  life:        f32,
  max_life:    f32,
  is_dead:     b32,
  weight:      f32,
  padding:     [2]f32,
}

ParticleSystemParams :: struct {
  particle_count: u32,
  emitter_count:  u32,
  forcefield_count:  u32,
  delta_time:     f32,
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
  // Particle pool management
  free_particle_indices:         [dynamic]int,
  active_particle_count:         u32,
  // Render pipeline
  render_descriptor_set_layout:  vk.DescriptorSetLayout,
  render_descriptor_set:         vk.DescriptorSet,
  render_pipeline_layout:        vk.PipelineLayout,
  render_pipeline:               vk.Pipeline,
  particle_texture:              ^ImageBuffer,
}

initialize_particle_pool :: proc(self: ^RendererParticle) {
  particles := slice.from_ptr(self.particle_buffer.mapped, MAX_PARTICLES)
  clear(&self.free_particle_indices)
  reserve(&self.free_particle_indices, MAX_PARTICLES)
  for &particle, i in particles {
    append(&self.free_particle_indices, i)
  }
  self.active_particle_count = 0
}

spawn_particle :: proc(
  self: ^RendererParticle,
  emitter_transform: linalg.Matrix4f32,
  emitter: ^Emitter,
) -> bool {
  if len(self.free_particle_indices) == 0 {
    return false
  }
  idx := pop(&self.free_particle_indices)
  particles := slice.from_ptr(self.particle_buffer.mapped, MAX_PARTICLES)
  particle := &particles[idx]
  particle.is_dead = false
  local_offset := linalg.Vector4f32 {
    rand.float32() * emitter.position_spread * 2.0 - emitter.position_spread,
    rand.float32() * emitter.position_spread * 2.0 - emitter.position_spread,
    rand.float32() * emitter.position_spread * 2.0 - emitter.position_spread,
    1.0,
  }
  particle.position = emitter_transform * local_offset
  velocity_variation := linalg.Vector4f32 {
    rand.float32() * emitter.velocity_spread * 2.0 - emitter.velocity_spread,
    rand.float32() * emitter.velocity_spread * 2.0 - emitter.velocity_spread,
    rand.float32() * emitter.velocity_spread * 2.0 - emitter.velocity_spread,
    0.0,
  }
  local_velocity := emitter.initial_velocity + velocity_variation
  particle.velocity = emitter_transform * local_velocity
  particle.life = emitter.particle_lifetime
  particle.max_life = emitter.particle_lifetime
  particle.color_start = emitter.color_start
  particle.color_end = emitter.color_end
  particle.color = emitter.color_start
  particle.size = emitter.size_start
  particle.size_end = emitter.size_end
  weight_variation :=
    rand.float32() * emitter.weight_spread * 2.0 - emitter.weight_spread
  particle.weight = emitter.weight + weight_variation
  self.active_particle_count += 1
  return true
}

recycle_dead_particles :: proc(self: ^RendererParticle) {
  particles := slice.from_ptr(self.particle_buffer.mapped, MAX_PARTICLES)
  for &particle, i in particles do if particle.life <= 0 && !particle.is_dead {
    append(&self.free_particle_indices, i)
    if self.active_particle_count > 0 {
      self.active_particle_count -= 1
    }
  }
}

compute_particles :: proc(
  self: ^RendererParticle,
  command_buffer: vk.CommandBuffer,
) {
  // log.info(
  //   "binding compute pipeline",
  //   renderer.pipeline_particle_comp.pipeline,
  // )
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
  // Insert memory barrier to ensure compute results are visible
  barrier := vk.MemoryBarrier {
    sType         = .MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.VERTEX_INPUT},
    {},
    1,
    &barrier,
    0,
    nil,
    0,
    nil,
  )
}

render_particles :: proc(
  self: ^RendererParticle,
  camera: geometry.Camera,
  command_buffer: vk.CommandBuffer,
) {
  // log.info(
  //   "binding particle render pipeline",
  //   engine.particle.pipeline,
  // )
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
    {.COMPUTE_SHADER}, // srcStageMask
    {.VERTEX_INPUT}, // dstStageMask
    {}, // dependencyFlags
    0,
    nil, // memoryBarrierCount, pMemoryBarriers
    1,
    &barrier, // bufferMemoryBarrierCount, pBufferMemoryBarriers
    0, // imageMemoryBarrierCount, pImageMemoryBarriers
    nil,
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.render_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.render_pipeline_layout,
    0,
    1,
    &self.render_descriptor_set,
    0,
    nil,
  )
  uniform := SceneUniform {
    view       = geometry.calculate_view_matrix(camera),
    projection = geometry.calculate_projection_matrix(camera),
  }
  vk.CmdPushConstants(
    command_buffer,
    self.render_pipeline_layout,
    {.VERTEX},
    0,
    size_of(SceneUniform),
    &uniform,
  )
  offset: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &self.particle_buffer.buffer,
    &offset,
  )
  vk.CmdDraw(command_buffer, MAX_PARTICLES, 1, 0, 0)
}

update_emitters :: proc(self: ^Engine, delta_time: f32) {
  params := data_buffer_get(&self.particle.params_buffer)
  params.delta_time = delta_time
  recycle_dead_particles(&self.particle)
  emitters := collect_emitters_for_particle_systems(&self.scene)
  params.emitter_count = u32(len(emitters))
  spawned_this_frame := 0
  for &entry in emitters {
    emitter := &entry.attachment.(EmitterAttachment)
    emitter_transform := entry.transform.world_matrix
    if !emitter.enabled {
      continue
    }
    emitter.time_accumulator += delta_time
    emission_interval := 1.0 / emitter.emission_rate
    for emitter.time_accumulator >= emission_interval {
      if !spawn_particle(&self.particle, emitter_transform, emitter) {
        break
      }
      spawned_this_frame += 1
      emitter.time_accumulator -= emission_interval
    }
  }
  params.particle_count = self.particle.active_particle_count
}

// Fill force field buffer each frame before compute dispatch
update_force_fields :: proc(self: ^Engine) {
  forcefield_nodes := collect_forcefields_for_particle_systems(&self.scene)
  forcefields := slice.from_ptr(
    self.particle.force_field_buffer.mapped,
    MAX_FORCE_FIELDS,
  )
  params := data_buffer_get(&self.particle.params_buffer)
  count := 0
  for &node in forcefield_nodes {
    if count >= MAX_FORCE_FIELDS {
      break
    }
    force_att, is_ff := &node.attachment.(ForceFieldAttachment)
    if !is_ff {
      continue
    }
    forcefield := force_att.force_field
    forcefield.position =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
    forcefields[count] = forcefield
    count += 1
  }
  params.forcefield_count = u32(count)
  for i in count ..< MAX_FORCE_FIELDS {
    forcefields[i] = ForceField{}
  }
}

renderer_particle_deinit :: proc(self: ^RendererParticle) {
  vk.DestroyPipeline(g_device, self.compute_pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.compute_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.compute_descriptor_set_layout,
    nil,
  )
  vk.DestroyPipeline(g_device, self.render_pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.render_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.render_descriptor_set_layout,
    nil,
  )
  delete(self.free_particle_indices)
  // Free buffers
}

renderer_particle_init :: proc(self: ^RendererParticle) -> vk.Result {
  self.params_buffer = create_host_visible_buffer(
    ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  self.particle_buffer = create_host_visible_buffer(
    Particle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER},
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
  self.free_particle_indices = make([dynamic]int, 0)
  initialize_particle_pool(self)
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
  params_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.params_buffer.buffer,
    range  = vk.DeviceSize(self.params_buffer.bytes_count),
  }
  particle_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.particle_buffer.buffer,
    range  = vk.DeviceSize(self.particle_buffer.bytes_count),
  }
  emitter_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.emitter_buffer.buffer,
    range  = vk.DeviceSize(self.emitter_buffer.bytes_count),
  }
  force_field_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.force_field_buffer.buffer,
    range  = vk.DeviceSize(self.force_field_buffer.bytes_count),
  }
  writes := [?]vk.WriteDescriptorSet {
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
      pBufferInfo = &emitter_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.compute_descriptor_set,
      dstBinding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &force_field_buffer_info,
    },
  }
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
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
  shader_module := create_shader_module(
    #load("shader/particle/compute.spv"),
  ) or_return
  defer vk.DestroyShaderModule(g_device, shader_module, nil)
  compute_pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = shader_module,
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
  render_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(render_bindings),
      pBindings = raw_data(render_bindings[:]),
    },
    nil,
    &self.render_descriptor_set_layout,
  ) or_return
  push_constant_range := [?]vk.PushConstantRange {
    {stageFlags = {.VERTEX}, size = size_of(SceneUniform)},
  }
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.render_descriptor_set_layout,
      pushConstantRangeCount = len(push_constant_range),
      pPushConstantRanges = raw_data(push_constant_range[:]),
    },
    nil,
    &self.render_pipeline_layout,
  ) or_return
  _, self.particle_texture = create_texture_from_path(
    "assets/black-circle.png",
  ) or_return
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.render_descriptor_set_layout,
    },
    &self.render_descriptor_set,
  ) or_return
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = self.render_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .COMBINED_IMAGE_SAMPLER,
    descriptorCount = 1,
    pImageInfo      = &{
      sampler = g_linear_repeat_sampler,
      imageView = self.particle_texture.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
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
      offset = u32(offset_of(Particle, velocity)),
    },
    {
      location = 2,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, color_start)),
    },
    {
      location = 3,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, color_end)),
    },
    {
      location = 4,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, color)),
    },
    {
      location = 5,
      binding = 0,
      format = .R32_SFLOAT,
      offset = u32(offset_of(Particle, size)),
    },
    {
      location = 6,
      binding = 0,
      format = .R32_SFLOAT,
      offset = u32(offset_of(Particle, size_end)),
    },
    {
      location = 7,
      binding = 0,
      format = .R32_SFLOAT,
      offset = u32(offset_of(Particle, life)),
    },
    {
      location = 8,
      binding = 0,
      format = .R32_SFLOAT,
      offset = u32(offset_of(Particle, max_life)),
    },
    {
      location = 9,
      binding = 0,
      format = .R32_UINT,
      offset = u32(offset_of(Particle, is_dead)),
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
    depthBiasEnable         = false,
    lineWidth               = 1,
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
    pDepthStencilState  = &{
      sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
      depthTestEnable = true,
      depthWriteEnable = false,
      depthCompareOp = .LESS_OR_EQUAL,
    },
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
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  depth_view: vk.ImageView,
) {
  // Update force fields before running compute shader
  update_force_fields(engine)

  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = color_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD, // preserve previous contents
    storeOp = .STORE,
    clearValue = {color = {float32 = {0, 0, 0, 0}}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = depth_view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = engine.swapchain.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(engine.swapchain.extent.height),
    width    = f32(engine.swapchain.extent.width),
    height   = -f32(engine.swapchain.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = engine.swapchain.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

renderer_particle_render :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  render_particles(&engine.particle, engine.scene.camera, command_buffer)
}

renderer_particle_end :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  vk.CmdEndRenderingKHR(command_buffer)
}

get_available_particle_count :: proc(self: ^RendererParticle) -> u32 {
  return u32(len(self.free_particle_indices))
}

get_particle_pool_stats :: proc(
  self: ^RendererParticle,
) -> (
  active: u32,
  free: u32,
  total: u32,
) {
  return self.active_particle_count,
    u32(len(self.free_particle_indices)),
    MAX_PARTICLES
}

// Collect all force field nodes for all particle systems
collect_force_field_nodes_for_particle_systems :: proc(
  scene: ^Scene,
) -> [dynamic]^Node {
  ctx := ForceFieldCollectContext{scene, make([dynamic]^Node, 0)}
  // Traverse all nodes
  scene_traverse(scene, &ctx, proc(node: ^Node, user_ctx: rawptr) -> bool {
    ctx := cast(^ForceFieldCollectContext)user_ctx
    _, is_force := &node.attachment.(ForceFieldAttachment)
    if is_force {
      append(&ctx.forcefields, node)
    }
    return true
  })
  return ctx.forcefields
}
