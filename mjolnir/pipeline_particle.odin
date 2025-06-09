package mjolnir

import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "geometry"
import vk "vendor:vulkan"

Emitter :: struct {
  transform:         geometry.Transform,
  emission_rate:     f32,
  particle_lifetime: f32,
  velocity_spread:   f32,
  time_accumulator:  f32,
  initial_velocity:  linalg.Vector4f32,
  color_start:       linalg.Vector4f32, // Start color (RGBA)
  color_end:         linalg.Vector4f32, // End color (RGBA)
  size_start:        f32,
  size_end:          f32,
  enabled:           b32,
  padding:           f32,
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
}

ParticleSystemParams :: struct {
  particle_count: u32,
  emitter_count:  u32,
  delta_time:     f32,
  padding:        f32,
}

// --- Vulkan Compute Pipeline Setup for Particles ---
PipelineParticleCompute :: struct {
  params_buffer:         DataBuffer(ParticleSystemParams),
  particle_buffer:       DataBuffer(Particle),
  emitter_buffer:        DataBuffer(Emitter),
  descriptor_set_layout: vk.DescriptorSetLayout,
  descriptor_set:        vk.DescriptorSet,
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  free_particle_indices: [dynamic]int,
}

PipelineParticle :: struct {
  descriptor_set_layout: vk.DescriptorSetLayout,
  descriptor_set:        vk.DescriptorSet,
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  particle_texture:      vk.Image,
  particle_sampler:      vk.Sampler,
  particle_view:         vk.ImageView,
}

setup_particle_compute_pipeline :: proc(
  pipeline: ^PipelineParticleCompute,
) -> (
  ret: vk.Result,
) {
  // 1. Create params buffer (uniform buffer)
  pipeline.params_buffer = create_host_visible_buffer(
    ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  params := data_buffer_get(pipeline.params_buffer)
  params.particle_count = 0
  params.emitter_count = 0
  params.delta_time = 0
  params.padding = 0
  // 2. Create particle buffer (storage + vertex buffer)
  pipeline.particle_buffer = create_host_visible_buffer(
    Particle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER},
  ) or_return
  // 3. Create emitter buffer (storage buffer)
  pipeline.emitter_buffer = create_host_visible_buffer(
    Emitter,
    MAX_EMITTERS,
    {.STORAGE_BUFFER},
  ) or_return
  // 4. Descriptor set layout
  bindings := [?]vk.DescriptorSetLayoutBinding {
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
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &pipeline.descriptor_set_layout,
  ) or_return
  log.info("compute descriptor set layout created", pipeline)
  // 5. Descriptor set allocation and update
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &pipeline.descriptor_set_layout,
    },
    &pipeline.descriptor_set,
  ) or_return
  params_buffer_info := vk.DescriptorBufferInfo {
    buffer = pipeline.params_buffer.buffer,
    range  = vk.DeviceSize(pipeline.params_buffer.bytes_count),
  }
  particle_buffer_info := vk.DescriptorBufferInfo {
    buffer = pipeline.particle_buffer.buffer,
    range  = vk.DeviceSize(pipeline.particle_buffer.bytes_count),
  }
  emitter_buffer_info := vk.DescriptorBufferInfo {
    buffer = pipeline.emitter_buffer.buffer,
    range  = vk.DeviceSize(pipeline.emitter_buffer.bytes_count),
  }
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = pipeline.descriptor_set,
      dstBinding = 0,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &params_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = pipeline.descriptor_set,
      dstBinding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &particle_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = pipeline.descriptor_set,
      dstBinding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &emitter_buffer_info,
    },
  }
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  // 6. Pipeline layout and compute pipeline
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &pipeline.descriptor_set_layout,
    },
    nil,
    &pipeline.pipeline_layout,
  ) or_return
  log.info("compute pipeline layout created", pipeline)
  shader_module := create_shader_module(
    #load("shader/particle/compute.spv"),
  ) or_return
  pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = shader_module,
      pName = "main",
    },
    layout = pipeline.pipeline_layout,
  }
  vk.CreateComputePipelines(
    g_device,
    0,
    1,
    &pipeline_info,
    nil,
    &pipeline.pipeline,
  ) or_return
  pipeline.free_particle_indices = make([dynamic]int, 0)
  ret = .SUCCESS
  log.info("compute pipeline created", pipeline)
  return
}

add_emitter :: proc(
  pipeline: ^PipelineParticleCompute,
  emitter: Emitter,
) -> vk.Result {
  params := data_buffer_get(pipeline.params_buffer)
  if params.emitter_count >= MAX_EMITTERS {
    return .ERROR_UNKNOWN
  }
  ptr := data_buffer_get(pipeline.emitter_buffer, params.emitter_count)
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

particle_render_pipeline_deinit :: proc(pipeline: ^PipelineParticle) {
  if pipeline == nil do return
  vk.DestroyPipeline(g_device, pipeline.pipeline, nil)
  vk.DestroyPipelineLayout(g_device, pipeline.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(g_device, pipeline.descriptor_set_layout, nil)
  vk.DestroyImageView(g_device, pipeline.particle_view, nil)
  vk.DestroyImage(g_device, pipeline.particle_texture, nil)
  vk.DestroySampler(g_device, pipeline.particle_sampler, nil)
}


remove_emitter :: proc(
  pipeline: ^PipelineParticleCompute,
  index: u32,
) -> vk.Result {
  params := data_buffer_get(pipeline.params_buffer)
  if index >= params.emitter_count {
    return .ERROR_UNKNOWN
  }
  emitters := pipeline.emitter_buffer.mapped
  if index < params.emitter_count {
    emitters[index] = emitters[params.emitter_count - 1]
  }
  params.emitter_count -= 1
  return .SUCCESS
}

update_emitters :: proc(pipeline: ^PipelineParticleCompute, delta_time: f32) {
  params := data_buffer_get(pipeline.params_buffer)
  params.delta_time = delta_time
  emitters := pipeline.emitter_buffer.mapped
  particles := pipeline.particle_buffer.mapped
  for i in 0 ..< MAX_PARTICLES {
    if particles[i].life <= 0 && !particles[i].is_dead {
      append(&pipeline.free_particle_indices, i)
      particles[i].is_dead = true
    }
  }
  // For each emitter, spawn as many particles as needed
  for e in 0 ..< params.emitter_count {
    emitter := &emitters[e]
    if !emitter.enabled do continue
    emitter.time_accumulator += delta_time
    emission_interval := 1.0 / emitter.emission_rate
    for emitter.time_accumulator >= emission_interval {
      idx, ok := pop_front_safe(&pipeline.free_particle_indices)
      if !ok {
        break
      }
      particles[idx].is_dead = false
      particles[idx].position = {
        emitter.transform.position.x,
        emitter.transform.position.y,
        emitter.transform.position.z,
        1.0,
      }
      particles[idx].velocity = emitter.initial_velocity
      particles[idx].life = emitter.particle_lifetime
      particles[idx].max_life = emitter.particle_lifetime
      particles[idx].color_start = emitter.color_start
      particles[idx].color_end = emitter.color_end
      particles[idx].color = emitter.color_start
      particles[idx].size = emitter.size_start
      emitter.time_accumulator -= emission_interval
    }
  }
  params.particle_count = u32(
    MAX_PARTICLES - len(pipeline.free_particle_indices),
  )
}

get_emitter :: proc(
  pipeline: ^PipelineParticleCompute,
  index: u32,
) -> ^Emitter {
  return data_buffer_get(pipeline.emitter_buffer, index)
}

set_emitter_enabled :: proc(
  pipeline: ^PipelineParticleCompute,
  index: u32,
  enabled: b32 = true,
) -> bool {
  emitter := get_emitter(pipeline, index)
  if emitter == nil {
    return false
  }
  emitter.enabled = enabled
  return true
}

set_emitter_transform :: proc(
  pipeline: ^PipelineParticleCompute,
  index: u32,
  transform: geometry.Transform,
) -> bool {
  emitter := get_emitter(pipeline, index)
  if emitter == nil {
    return false
  }
  emitter.transform = transform
  return true
}

set_emitter_properties :: proc(
  pipeline: ^PipelineParticleCompute,
  index: u32,
  emission_rate: f32 = 0,
  particle_lifetime: f32 = 0,
  initial_velocity: linalg.Vector4f32 = {},
  velocity_spread: f32 = 0,
  color_start: linalg.Vector4f32 = {1, 1, 1, 1},
  color_end: linalg.Vector4f32 = {1, 1, 1, 0},
  size_start: f32 = 1,
  size_end: f32 = 1,
) -> bool {
  emitter := get_emitter(pipeline, index)
  if emitter == nil {
    return false
  }
  if emission_rate > 0 do emitter.emission_rate = emission_rate
  if particle_lifetime > 0 do emitter.particle_lifetime = particle_lifetime
  if linalg.length(initial_velocity) > 0 do emitter.initial_velocity = initial_velocity
  if velocity_spread >= 0 do emitter.velocity_spread = velocity_spread
  emitter.color_start = color_start
  emitter.color_end = color_end
  if size_start > 0 do emitter.size_start = size_start
  if size_end > 0 do emitter.size_end = size_end
  return true
}

setup_particle_render_pipeline :: proc(
  pipeline: ^PipelineParticle,
) -> (
  ret: vk.Result,
) {
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings),
    pBindings    = raw_data(bindings[:]),
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &layout_info,
    nil,
    &pipeline.descriptor_set_layout,
  ) or_return
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    offset     = 0,
    size       = size_of(SceneUniform),
  }
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &pipeline.descriptor_set_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &pipeline.pipeline_layout,
  ) or_return
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
    layout              = pipeline.pipeline_layout,
    pNext               = &rendering_info,
    pDepthStencilState  = &vk.PipelineDepthStencilStateCreateInfo {
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
    &pipeline.pipeline,
  ) or_return
  create_particle_texture(pipeline) or_return
  ret = .SUCCESS
  return
}

create_particle_texture :: proc(pipeline: ^PipelineParticle) -> vk.Result {
  texture: Texture
  read_texture(&texture, "assets/black-circle.png") or_return
  texture_init(&texture) or_return
  pipeline.particle_texture = texture.buffer.image
  pipeline.particle_view = texture.buffer.view
  pipeline.particle_sampler = texture.sampler
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &pipeline.descriptor_set_layout,
    },
    &pipeline.descriptor_set,
  ) or_return
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = pipeline.descriptor_set,
    dstBinding      = 0,
    descriptorType  = .COMBINED_IMAGE_SAMPLER,
    descriptorCount = 1,
    pImageInfo      = &{
      sampler = pipeline.particle_sampler,
      imageView = pipeline.particle_view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  return .SUCCESS
}
