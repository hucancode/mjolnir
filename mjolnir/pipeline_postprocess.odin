package mjolnir

import "core:log"
import vk "vendor:vulkan"

// Effect data structures
GrayscaleEffect :: struct {
  weights:  [3]f32,
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
  padding:  [2]f32,
}

BlurEffect :: struct {
  radius:  f32,
  padding: [3]f32,
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
  padding:     f32,
}

OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

PostProcessEffectType :: enum (int) {
  GRAYSCALE,
  TONEMAP,
  BLUR,
  BLOOM,
  OUTLINE,
  NONE,
}

PostprocessEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
}

// Main postprocess pipeline structure
PipelinePostProcess :: struct {
  pipelines:              [len(PostProcessEffectType)]vk.Pipeline,
  pipeline_layouts:       [len(PostProcessEffectType)]vk.PipelineLayout,
  descriptor_sets:        [3]vk.DescriptorSet,
  descriptor_set_layouts: [1]vk.DescriptorSetLayout,
  sampler:                vk.Sampler,
  effect_stack:           [dynamic]PostprocessEffect,
}

// Effect type resolution
postprocess_get_effect_type :: proc(
  effect: PostprocessEffect,
) -> PostProcessEffectType {
  switch _ in effect {
  case GrayscaleEffect:
    return .GRAYSCALE
  case ToneMapEffect:
    return .TONEMAP
  case BlurEffect:
    return .BLUR
  case BloomEffect:
    return .BLOOM
  case OutlineEffect:
    return .OUTLINE
  }
  return .NONE
}

// Deprecated - use postprocess_get_effect_type instead
type_of_effect :: proc(
  effect: PostprocessEffect,
) -> PostProcessEffectType {
  return postprocess_get_effect_type(effect)
}

effect_add_grayscale :: proc(
  pipeline: ^PipelinePostProcess,
  strength: f32 = 1.0,
  weights: [3]f32 = {0.299, 0.587, 0.114},
) {
  effect := GrayscaleEffect {
    strength = strength,
    weights  = weights,
  }
  append(&pipeline.effect_stack, effect)
}

effect_add_blur :: proc(pipeline: ^PipelinePostProcess, radius: f32) {
  effect := BlurEffect {
    radius = radius,
  }
  append(&pipeline.effect_stack, effect)
}

effect_add_bloom :: proc(
  pipeline: ^PipelinePostProcess,
  threshold: f32 = 0.2,
  intensity: f32 = 1.0,
  blur_radius: f32 = 4.0,
) {
  effect := BloomEffect {
    threshold   = threshold,
    intensity   = intensity,
    blur_radius = blur_radius,
  }
  append(&pipeline.effect_stack, effect)
}

effect_add_tonemap :: proc(
  pipeline: ^PipelinePostProcess,
  exposure: f32 = 1.0,
  gamma: f32 = 2.2,
) {
  effect := ToneMapEffect {
    exposure = exposure,
    gamma    = gamma,
  }
  append(&pipeline.effect_stack, effect)
}

effect_add_outline :: proc(
  pipeline: ^PipelinePostProcess,
  thickness: f32,
  color: [3]f32,
) {
  effect := OutlineEffect {
    thickness = thickness,
    color     = color,
  }
  append(&pipeline.effect_stack, effect)
}

effect_clear :: proc(pipeline: ^PipelinePostProcess) {
  resize(&pipeline.effect_stack, 0)
}


postprocess_update_input :: proc(
  pipeline: ^PipelinePostProcess,
  set_idx: int,
  input_view: vk.ImageView,
) -> vk.Result {
  image_info := vk.DescriptorImageInfo {
    sampler     = pipeline.sampler,
    imageView   = input_view,
    imageLayout = .SHADER_READ_ONLY_OPTIMAL,
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = pipeline.descriptor_sets[set_idx],
    dstBinding      = 0,
    descriptorType  = .COMBINED_IMAGE_SAMPLER,
    descriptorCount = 1,
    pImageInfo      = &image_info,
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  return .SUCCESS
}

// Shader loading
SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")
SHADER_POSTPROCESS_FRAG :: #load("shader/postprocess/frag.spv")
SHADER_BLOOM_FRAG :: #load("shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("shader/outline/frag.spv")

// Shader module creation helper
postprocess_create_fragment_shader :: proc(
  effect_type: PostProcessEffectType,
) -> (
  vk.ShaderModule,
  vk.Result,
) {
  shader_code: []u8
  switch effect_type {
  case .BLOOM:
    shader_code = SHADER_BLOOM_FRAG
  case .BLUR:
    shader_code = SHADER_BLUR_FRAG
  case .GRAYSCALE:
    shader_code = SHADER_GRAYSCALE_FRAG
  case .TONEMAP:
    shader_code = SHADER_TONEMAP_FRAG
  case .OUTLINE:
    shader_code = SHADER_OUTLINE_FRAG
  case .NONE:
    shader_code = SHADER_POSTPROCESS_FRAG
  }
  return create_shader_module(shader_code)
}

// Push constant size helper
postprocess_get_push_constant_size :: proc(
  effect_type: PostProcessEffectType,
) -> u32 {
  switch effect_type {
  case .BLUR:
    return size_of(BlurEffect)
  case .OUTLINE:
    return size_of(OutlineEffect)
  case .GRAYSCALE:
    return size_of(GrayscaleEffect)
  case .BLOOM:
    return size_of(BloomEffect)
  case .TONEMAP:
    return size_of(ToneMapEffect)
  case .NONE:
    return 0
  }
  return 0
}

postprocess_pipeline_init :: proc(
  pipeline: ^PipelinePostProcess,
  color_format: vk.Format,
  width: u32,
  height: u32,
) -> vk.Result {
  log.info("Initializing postprocess pipeline...")

  // Initialize effect stack
  pipeline.effect_stack = make([dynamic]PostprocessEffect)

  return postprocess_build_pipelines(pipeline, color_format, width, height)
}

// Main pipeline building function
postprocess_build_pipelines :: proc(
  pipeline: ^PipelinePostProcess,
  color_format: vk.Format,
  width: u32,
  height: u32,
) -> vk.Result {
  log.info("Building postprocess pipelines...")
  count :: len(PostProcessEffectType)

  // Create vertex shader module
  vert_module := create_shader_module(SHADER_POSTPROCESS_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)

  // Create fragment shader modules
  frag_modules: [count]vk.ShaderModule
  defer for module in frag_modules do vk.DestroyShaderModule(g_device, module, nil)

  for effect_type, i in PostProcessEffectType {
    frag_modules[i] = postprocess_create_fragment_shader(effect_type) or_return
  }

  // Setup common pipeline state
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }

  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }

  color_formats := [?]vk.Format{color_format}
  rendering_info := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
  }

  // Common pipeline state objects
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
  }
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = false,
    depthWriteEnable = false,
  }

  // Create descriptor set layouts
  postprocess_create_descriptor_set_layouts(pipeline) or_return

  // Allocate descriptor sets
  postprocess_allocate_descriptor_sets(pipeline) or_return

  // Create pipelines for each effect type
  for effect_type, i in PostProcessEffectType {
    // Create push constant range
    push_constant_size := postprocess_get_push_constant_size(effect_type)
    push_constant_range := vk.PushConstantRange {
      stageFlags = {.FRAGMENT},
      size       = push_constant_size,
    }

    // Create pipeline layout
    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = len(pipeline.descriptor_set_layouts),
      pSetLayouts            = raw_data(pipeline.descriptor_set_layouts[:]),
      pushConstantRangeCount = 1 if push_constant_size > 0 else 0,
      pPushConstantRanges    = &push_constant_range if push_constant_size > 0 else nil,
    }
    vk.CreatePipelineLayout(
      g_device,
      &pipeline_layout_info,
      nil,
      &pipeline.pipeline_layouts[i],
    ) or_return

    // Create shader stages
    shader_stages := [2]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_modules[i],
        pName = "main",
      },
    }

    // Create graphics pipeline
    pipeline_info := vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info,
      stageCount          = len(shader_stages),
      pStages             = raw_data(shader_stages[:]),
      pVertexInputState   = &vertex_input,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &color_blending,
      pDepthStencilState  = &depth_stencil_state,
      pDynamicState       = &dynamic_state,
      layout              = pipeline.pipeline_layouts[i],
    }

    vk.CreateGraphicsPipelines(
      g_device,
      0,
      1,
      &pipeline_info,
      nil,
      &pipeline.pipelines[i],
    ) or_return
  }

  // Create sampler
  postprocess_create_sampler(pipeline) or_return

  log.info("Postprocess pipeline initialized successfully")
  return .SUCCESS
}

// Helper function to create descriptor set layouts
postprocess_create_descriptor_set_layouts :: proc(
  pipeline: ^PipelinePostProcess,
) -> vk.Result {
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
  for &set_layout in pipeline.descriptor_set_layouts {
    vk.CreateDescriptorSetLayout(
      g_device,
      &layout_info,
      nil,
      &set_layout,
    ) or_return
  }
  return .SUCCESS
}

// Helper function to allocate descriptor sets
postprocess_allocate_descriptor_sets :: proc(
  pipeline: ^PipelinePostProcess,
) -> vk.Result {
  // We need 3 descriptor sets for ping-pong rendering between postprocess passes
  for i in 0 ..< 3 {
    vk.AllocateDescriptorSets(
      g_device,
      &vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = g_descriptor_pool,
        descriptorSetCount = len(pipeline.descriptor_set_layouts),
        pSetLayouts = raw_data(pipeline.descriptor_set_layouts[:]),
      },
      &pipeline.descriptor_sets[i],
    ) or_return
  }
  return .SUCCESS
}

// Helper function to create sampler
postprocess_create_sampler :: proc(
  pipeline: ^PipelinePostProcess,
) -> vk.Result {
  sampler_info := vk.SamplerCreateInfo {
    sType        = .SAMPLER_CREATE_INFO,
    magFilter    = .LINEAR,
    minFilter    = .LINEAR,
    addressModeU = .CLAMP_TO_EDGE,
    addressModeV = .CLAMP_TO_EDGE,
    addressModeW = .CLAMP_TO_EDGE,
    mipmapMode   = .LINEAR,
    minLod       = 0.0,
    maxLod       = 0.0,
    borderColor  = .FLOAT_OPAQUE_WHITE,
  }
  vk.CreateSampler(g_device, &sampler_info, nil, &pipeline.sampler) or_return
  return .SUCCESS
}

postprocess_pipeline_deinit :: proc(pipeline: ^PipelinePostProcess) {
  // Clean up pipelines
  for &p in pipeline.pipelines {
    if p != 0 {
      vk.DestroyPipeline(g_device, p, nil)
      p = 0
    }
  }

  // Clean up pipeline layouts
  for &layout in pipeline.pipeline_layouts {
    if layout != 0 {
      vk.DestroyPipelineLayout(g_device, layout, nil)
      layout = 0
    }
  }

  // Clean up descriptor set layouts
  for &set_layout in pipeline.descriptor_set_layouts {
    if set_layout != 0 {
      vk.DestroyDescriptorSetLayout(g_device, set_layout, nil)
      set_layout = 0
    }
  }

  // Clean up sampler
  if pipeline.sampler != 0 {
    vk.DestroySampler(g_device, pipeline.sampler, nil)
    pipeline.sampler = 0
  }

  // Clean up effect stack
  if pipeline.effect_stack != nil {
    delete(pipeline.effect_stack)
  }
}
