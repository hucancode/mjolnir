package mjolnir

import linalg "core:math/linalg"
import "geometry"
import vk "vendor:vulkan"

Emitter :: struct {
  transform:         geometry.Transform,
  emission_rate:     f32, // Particles per second
  particle_lifetime: f32,
  initial_velocity:  linalg.Vector3f32,
  velocity_spread:   f32,
  color_start:       linalg.Vector4f32, // Start color (RGBA)
  color_end:         linalg.Vector4f32, // End color (RGBA)
  size_start:        f32,
  size_end:          f32,
  enabled:           bool,
  time_accumulator:  f32,
}

MAX_EMITTERS :: 64
MAX_PARTICLES :: 65536

Particle :: struct {
  position:    linalg.Vector3f32,
  size:        f32,
  velocity:    linalg.Vector3f32,
  life:    f32,
  color_start: linalg.Vector4f32,
  color_end:   linalg.Vector4f32,
  color:       linalg.Vector4f32,
  max_life:    f32,
}

ParticleSystemParams :: struct {
  particle_count: u32,
  emitter_count:  u32,
  delta_time:     f32,
  padding:        f32,
}

// --- Vulkan Compute Pipeline Setup for Particles ---
ParticleComputePipeline :: struct {
  params_buffer:         DataBuffer(ParticleSystemParams),
  particle_buffer:       DataBuffer(Particle),
  emitter_buffer:        DataBuffer(Emitter),
  descriptor_set_layout: vk.DescriptorSetLayout,
  descriptor_set:        vk.DescriptorSet,
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
}

setup_particle_compute_pipeline :: proc(
) -> (
  pipeline: ParticleComputePipeline,
  ret: vk.Result,
) {

  // 1. Create params buffer (uniform buffer)
  pipeline.params_buffer = create_host_visible_buffer(
    ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  // 2. Create particle buffer (storage buffer)
  pipeline.particle_buffer = create_host_visible_buffer(
    Particle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER},
  ) or_return


  // 3. Create emitter buffer (storage buffer)
  pipeline.emitter_buffer = create_host_visible_buffer(
    Emitter,
    MAX_EMITTERS,
    {.STORAGE_BUFFER},
  ) or_return

  // 3. Descriptor set layout
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

  // 4. Descriptor set allocation and update
  vk.AllocateDescriptorSets(
    g_device,
    &vk.DescriptorSetAllocateInfo {
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

  // 5. Pipeline layout and compute pipeline
  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType          = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount = 1,
    pSetLayouts    = &pipeline.descriptor_set_layout,
  }
  vk.CreatePipelineLayout(
    g_device,
    &pipeline_layout_info,
    nil,
    &pipeline.pipeline_layout,
  ) or_return

  shader_module := create_shader_module(
    #load("shader/particle/compute.spv"),
  ) or_return

  pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = vk.PipelineShaderStageCreateInfo {
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
  ret = .SUCCESS
  return
}

add_emitter :: proc(
  pipeline: ^ParticleComputePipeline,
  emitter: Emitter,
) -> vk.Result {
  params := data_buffer_get(pipeline.params_buffer)
  if params.emitter_count >= MAX_EMITTERS {
    return .ERROR_UNKNOWN
  }
  ptr := data_buffer_get(pipeline.emitter_buffer, params.emitter_count)
  ptr^ = emitter
  params.emitter_count += 1
  return .SUCCESS
}

remove_emitter :: proc(
  pipeline: ^ParticleComputePipeline,
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

update_emitters :: proc(pipeline: ^ParticleComputePipeline, delta_time: f32) {
  params := data_buffer_get(pipeline.params_buffer)
  params.delta_time = delta_time
  for i in 0 ..< params.emitter_count {
    get_emitter(pipeline, i).time_accumulator += delta_time
  }
}

get_emitter :: proc(
  pipeline: ^ParticleComputePipeline,
  index: u32,
) -> ^Emitter {
  return data_buffer_get(pipeline.emitter_buffer, index)
}

set_emitter_enabled :: proc(
  pipeline: ^ParticleComputePipeline,
  index: u32,
  enabled: bool = true,
) -> bool {
  emitter := get_emitter(pipeline, index)
  if emitter == nil {
    return false
  }
  emitter.enabled = enabled
  return true
}

set_emitter_transform :: proc(
  pipeline: ^ParticleComputePipeline,
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
  pipeline: ^ParticleComputePipeline,
  index: u32,
  emission_rate: f32 = 0,
  particle_lifetime: f32 = 0,
  initial_velocity: linalg.Vector3f32 = {},
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
