package mjolnir

import "core:log"
import vk "vendor:vulkan"

GrayscaleEffect :: struct {
  weights:  [3]f32,
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

BlurEffect :: struct {
  radius: f32,
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
  padding: f32,
}

OutlineEffect :: struct {
  color:      [3]f32,
  thickness: f32,
}

PostProcessEffectType :: enum (int) {
  GRAYSCALE,
  TONEMAP,
  BLUR,
  BLOOM,
  OUTLINE,
  COPY,
}

PostprocessEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
}

// Global postprocess stack
g_postprocess_stack: [dynamic]PostprocessEffect
g_postprocess_images: [2]ImageBuffer
g_postprocess_simple_sampler: vk.Sampler

type_of_postprocess_effect :: proc(
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
  // effect = nil
  return .COPY
}

// Add an effect to the stack
postprocess_push_grayscale :: proc(
  strength: f32 = 1.0,
  weights: [3]f32 = {0.299, 0.587, 0.114},
) {
  pipeline := &g_postprocess_pipelines[PostProcessEffectType.GRAYSCALE]
  effect := GrayscaleEffect {
    strength = strength,
    weights  = weights,
  }
  append(&g_postprocess_stack, effect)
}

postprocess_push_blur :: proc(radius: f32) {
  pipeline := &g_postprocess_pipelines[PostProcessEffectType.GRAYSCALE]
  effect := BlurEffect{radius}
  append(&g_postprocess_stack, effect)
}

postprocess_push_bloom :: proc(threshold: f32 = 0.2, intensity: f32 = 1.0, radius: f32 = 4.0) {
  pipeline := &g_postprocess_pipelines[PostProcessEffectType.BLOOM]
  effect := BloomEffect{
    threshold = threshold,
    intensity = intensity,
    blur_radius = radius,
  }
  append(&g_postprocess_stack, effect)
}

postprocess_push_tonemap :: proc(exposure: f32 = 1.0, gamma: f32 = 2.2) {
  pipeline := &g_postprocess_pipelines[PostProcessEffectType.TONEMAP]
  effect := ToneMapEffect{
    exposure = exposure,
    gamma    = gamma,
  }
  append(&g_postprocess_stack, effect)
}

postprocess_push_outline :: proc(thickness: f32, color: [3]f32) {
  pipeline := &g_postprocess_pipelines[PostProcessEffectType.OUTLINE]
  effect := OutlineEffect{
    thickness = thickness,
    color     = color,
  }
  append(&g_postprocess_stack, effect)
}

// Clear all effects
clear_postprocess_effects :: proc() {
  for &effect in g_postprocess_stack {
    // descriptor sets are freed with the pool
    // TODO: but when the pool get overflow we need to free this manually
  }
  resize(&g_postprocess_stack, 0)
}

// TODO: use 1 dedicated descriptor set for each effect
// otherwise we can not stack multiple post process effect
update_postprocess_input :: proc(
  input_view: vk.ImageView,
) -> vk.Result {
  image_info := vk.DescriptorImageInfo {
    sampler     = g_postprocess_simple_sampler,
    imageView   = input_view,
    imageLayout = .SHADER_READ_ONLY_OPTIMAL,
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = g_postprocess_descriptor_sets[0],
    dstBinding      = 0,
    descriptorType  = .COMBINED_IMAGE_SAMPLER,
    descriptorCount = 1,
    pImageInfo      = &image_info,
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  log.infof(
    "update descriptor set %v, use image view %v",
    g_postprocess_descriptor_sets[0],
    input_view,
  )
  return .SUCCESS
}

SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")
SHADER_POSTPROCESS_FRAG :: #load("shader/postprocess/frag.spv")
SHADER_BLOOM_FRAG :: #load("shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("shader/outline/frag.spv")

g_postprocess_pipelines: [len(PostProcessEffectType)]vk.Pipeline
g_postprocess_pipeline_layouts: [len(PostProcessEffectType)]vk.PipelineLayout
g_postprocess_descriptor_sets: [1]vk.DescriptorSet
g_postprocess_descriptor_set_layouts: [1]vk.DescriptorSetLayout

build_postprocess_pipelines :: proc(color_format: vk.Format, width: u32, height: u32) -> vk.Result {
  log.info("building post processing pipelines...")
  count :: len(PostProcessEffectType)
  vert_module := create_shader_module(SHADER_POSTPROCESS_VERT) or_return
  frag_modules: [count]vk.ShaderModule
  pipeline_infos: [count]vk.GraphicsPipelineCreateInfo
  shader_stages: [count][2]vk.PipelineShaderStageCreateInfo
  push_constant_ranges: [count]vk.PushConstantRange

  defer for module in frag_modules do vk.DestroyShaderModule(g_device, module, nil)
  defer vk.DestroyShaderModule(g_device, vert_module, nil)

  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  // Enable dynamic state for viewport and scissor
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo{
    sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates = raw_data(dynamic_states[:]),
  }
  color_formats := [?]vk.Format{color_format}
  log.infof("PipelineRenderingCreateInfoKHR: colorAttachmentFormats[0]=%d", color_formats[0]);
  rendering_info := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
  }
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
  for &set_layout in g_postprocess_descriptor_set_layouts {
    vk.CreateDescriptorSetLayout(
      g_device,
      &layout_info,
      nil,
      &set_layout,
    ) or_return
  }
  vk.AllocateDescriptorSets(
    g_device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = len(g_postprocess_descriptor_set_layouts),
      pSetLayouts = raw_data(g_postprocess_descriptor_set_layouts[:]),
    },
    raw_data(g_postprocess_descriptor_sets[:]),
  ) or_return

  for effect_type, i in PostProcessEffectType {
    switch effect_type {
    case .BLOOM:
      frag_modules[i] = create_shader_module(SHADER_BLOOM_FRAG) or_return
    case .BLUR:
      frag_modules[i] = create_shader_module(SHADER_BLUR_FRAG) or_return
    case .GRAYSCALE:
      frag_modules[i] = create_shader_module(SHADER_GRAYSCALE_FRAG) or_return
    case .TONEMAP:
      frag_modules[i] = create_shader_module(SHADER_TONEMAP_FRAG) or_return
    case .OUTLINE:
      frag_modules[i] = create_shader_module(SHADER_OUTLINE_FRAG) or_return
    case .COPY:
      frag_modules[i] = create_shader_module(SHADER_POSTPROCESS_FRAG) or_return
    }

    switch effect_type {
    case .BLUR:
      push_constant_ranges[i] = {
        stageFlags = {.FRAGMENT},
        size       = size_of(BlurEffect),
      }
    case .OUTLINE:
      push_constant_ranges[i] = {
        stageFlags = {.FRAGMENT},
        size       = size_of(OutlineEffect),
      }
    case .GRAYSCALE:
      push_constant_ranges[i] = {
        stageFlags = {.FRAGMENT},
        size       = size_of(GrayscaleEffect),
      }
    case .BLOOM:
      push_constant_ranges[i] = {
        stageFlags = {.FRAGMENT},
        size       = size_of(BloomEffect),
      }
    case .TONEMAP:
      push_constant_ranges[i] = {
        stageFlags = {.FRAGMENT},
        size       = size_of(ToneMapEffect),
      }
    case .COPY:
      push_constant_ranges[i] = {
        stageFlags = {.FRAGMENT},
        size       = 0,
      }
    }
    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = len(g_postprocess_descriptor_set_layouts),
      pSetLayouts            = raw_data(
        g_postprocess_descriptor_set_layouts[:],
      ),
      pushConstantRangeCount = 1,
      pPushConstantRanges    = &push_constant_ranges[i],
    }
    vk.CreatePipelineLayout(
      g_device,
      &pipeline_layout_info,
      nil,
      &g_postprocess_pipeline_layouts[i],
    ) or_return

    flags: vk.PipelineCreateFlags =
      {.ALLOW_DERIVATIVES} if i == 0 else {.DERIVATIVE}

    shader_stages[i] = [2]vk.PipelineShaderStageCreateInfo {
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

    pipeline_infos[i] = vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info,
      stageCount          = len(shader_stages[i]),
      pStages             = raw_data(shader_stages[i][:]),
      pVertexInputState   = &vertex_input,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &color_blending,
      pDepthStencilState  = &depth_stencil_state,
      pDynamicState       = &dynamic_state,
      layout              = g_postprocess_pipeline_layouts[i],
      // flags               = flags,
      // basePipelineIndex   = 0,
    }
  }

  vk.CreateGraphicsPipelines(
    g_device,
    0,
    count,
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(g_postprocess_pipelines[:]),
  ) or_return

  sampler_info := vk.SamplerCreateInfo{
      sType = .SAMPLER_CREATE_INFO,
      magFilter = .LINEAR,
      minFilter = .LINEAR,
      addressModeU = .CLAMP_TO_EDGE,
      addressModeV = .CLAMP_TO_EDGE,
      addressModeW = .CLAMP_TO_EDGE,
      mipmapMode = .LINEAR,
      minLod = 0.0,
      maxLod = 0.0,
      borderColor = .FLOAT_OPAQUE_WHITE,
  }
  vk.CreateSampler(g_device, &sampler_info, nil, &g_postprocess_simple_sampler) or_return
  for &image, i in g_postprocess_images {
      image = malloc_image_buffer(
          width, // swapchain or main pass width
          height, // swapchain or main pass height
          color_format, // swapchain format, e.g. VK_FORMAT_B8G8R8A8_SRGB
          .OPTIMAL,
          {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
          {.DEVICE_LOCAL},
      ) or_return

      image.view = create_image_view(
          image.image,
          color_format,
          {.COLOR},
      ) or_return
  }
  return .SUCCESS
}

postprocess_pipeline_deinit :: proc() {
  for &pipeline in g_postprocess_pipelines {
    vk.DestroyPipeline(g_device, pipeline, nil)
    pipeline = 0
  }
  for &layout in g_postprocess_pipeline_layouts {
    vk.DestroyPipelineLayout(g_device, layout, nil)
    layout = 0
  }
  for &set_layout in g_postprocess_descriptor_set_layouts {
    vk.DestroyDescriptorSetLayout(g_device, set_layout, nil)
    set_layout = 0
  }
}
