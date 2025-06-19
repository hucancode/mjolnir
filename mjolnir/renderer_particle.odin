package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "geometry"
import vk "vendor:vulkan"

Emitter :: struct {
  transform:         geometry.Transform,
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

MAX_EMITTERS :: 64
MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256

Particle :: struct {
  position:    linalg.Vector4f32,
  velocity:    linalg.Vector4f32,
  color_start: linalg.Vector4f32,
  color_end:   linalg.Vector4f32,
  color:       linalg.Vector4f32,
  size:        f32,
  life:        f32,
  max_life:    f32,
  is_dead:     b32,
  weight:      f32,
  padding:     [3]f32,
}

ParticleSystemParams :: struct {
  particle_count: u32,
  emitter_count:  u32,
  delta_time:     f32,
  padding:        f32,
}

RendererParticle :: struct {
  // Compute pipeline
  params_buffer:                 DataBuffer(ParticleSystemParams),
  particle_buffer:               DataBuffer(Particle),
  emitter_buffer:                DataBuffer(Emitter),
  compute_descriptor_set_layout: vk.DescriptorSetLayout,
  compute_descriptor_set:        vk.DescriptorSet,
  compute_pipeline_layout:       vk.PipelineLayout,
  compute_pipeline:              vk.Pipeline,
  free_particle_indices:         [dynamic]int,
  // Render pipeline
  render_descriptor_set_layout:  vk.DescriptorSetLayout,
  render_descriptor_set:         vk.DescriptorSet,
  render_pipeline_layout:        vk.PipelineLayout,
  render_pipeline:               vk.Pipeline,
  particle_texture:              ^ImageBuffer,
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
  params := data_buffer_get(&self.params_buffer)
  vk.CmdDraw(command_buffer, u32(params.particle_count), 1, 0, 0)
}

add_emitter :: proc(self: ^RendererParticle, emitter: Emitter) -> vk.Result {
  params := data_buffer_get(&self.params_buffer)
  if params.emitter_count >= MAX_EMITTERS {
    return .ERROR_UNKNOWN
  }
  ptr := data_buffer_get(&self.emitter_buffer, params.emitter_count)
  ptr^ = emitter
  params.emitter_count += 1
  log.debugf(
    "[Particle System] Added emitter %d: rate=%.1f, lifetime=%.1f",
    params.emitter_count,
    emitter.emission_rate,
    emitter.particle_lifetime,
  )
  return .SUCCESS
}

update_emitters :: proc(self: ^RendererParticle, delta_time: f32) {
  params := data_buffer_get(&self.params_buffer)
  params.delta_time = delta_time
  emitters := slice.from_ptr(
    self.emitter_buffer.mapped,
    int(params.emitter_count),
  )
  particles := slice.from_ptr(self.particle_buffer.mapped, MAX_PARTICLES)
  for &particle, i in particles {
    if particle.life <= 0 && !particle.is_dead {
      append(&self.free_particle_indices, i)
      particle.is_dead = true
    }
  }
  // For each emitter, spawn as many particles as needed
  for &emitter in emitters {
    if !emitter.enabled do continue
    emitter.time_accumulator += delta_time
    emission_interval := 1.0 / emitter.emission_rate
    for emitter.time_accumulator >= emission_interval {
      idx, ok := pop_front_safe(&self.free_particle_indices)
      if !ok {
        break
      }
      particles[idx].is_dead = false
      particles[idx].position.xyz =
        emitter.transform.position +
        {
            rand.float32() * emitter.position_spread * 2.0 -
            emitter.position_spread,
            rand.float32() * emitter.position_spread * 2.0 -
            emitter.position_spread,
            rand.float32() * emitter.position_spread * 2.0 -
            emitter.position_spread,
          }
      particles[idx].position.w = 1.0
      particles[idx].velocity =
        emitter.initial_velocity +
        {
            rand.float32() * emitter.velocity_spread * 2.0 -
            emitter.velocity_spread,
            rand.float32() * emitter.velocity_spread * 2.0 -
            emitter.velocity_spread,
            rand.float32() * emitter.velocity_spread * 2.0 -
            emitter.velocity_spread,
            0.0,
          }
      particles[idx].life = emitter.particle_lifetime
      particles[idx].max_life = emitter.particle_lifetime
      particles[idx].color_start = emitter.color_start
      particles[idx].color_end = emitter.color_end
      particles[idx].color = emitter.color_start
      particles[idx].size = emitter.size_start
      particles[idx].weight =
        emitter.weight +
        (rand.float32() * emitter.weight_spread * 2.0 - emitter.weight_spread)
      emitter.time_accumulator -= emission_interval
    }
  }
  params.particle_count = u32(MAX_PARTICLES - len(self.free_particle_indices))
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
  // Free buffers
}

renderer_particle_init :: proc(self: ^RendererParticle) -> vk.Result {
  // Compute pipeline setup
  self.params_buffer = create_host_visible_buffer(
    ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  params := data_buffer_get(&self.params_buffer)
  params.particle_count = 0
  params.emitter_count = 0
  params.delta_time = 0
  params.padding = 0
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
  self.free_particle_indices = make([dynamic]int, 0)
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
  // Render pipeline setup
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
      offset = u32(offset_of(Particle, life)),
    },
    {
      location = 7,
      binding = 0,
      format = .R32_SFLOAT,
      offset = u32(offset_of(Particle, max_life)),
    },
    {
      location = 8,
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
