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
}

OutlineEffect :: struct {
  color:      [3]f32,
  line_width: f32,
}

PostProcessEffectType :: enum (int) {
  GRAYSCALE,
  TONEMAP,
  BLUR,
  BLOOM,
  OUTLINE,
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

type_of_postprocess_effect :: proc(effect: PostprocessEffect) -> PostProcessEffectType {
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
    return .GRAYSCALE
}

// Add an effect to the stack
postprocess_push_grayscale :: proc(
  strength: f32,
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

// Clear all effects
clear_postprocess_effects :: proc() {
  for &effect in g_postprocess_stack {
    // descriptor sets are freed with the pool
    // TODO: but when the pool get overflow we need to free this manually
  }
  resize(&g_postprocess_stack, 0)
}

update_postprocess_input :: proc(
  input_view: vk.ImageView,
  input_sampler: vk.Sampler,
) -> vk.Result {
  image_info := vk.DescriptorImageInfo {
    sampler     = input_sampler,
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
  return .SUCCESS
}

SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")
SHADER_BLOOM_FRAG :: #load("shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("shader/outline/frag.spv")

g_postprocess_pipelines: [len(PostProcessEffectType)]vk.Pipeline
g_postprocess_pipeline_layouts: [len(PostProcessEffectType)]vk.PipelineLayout
g_postprocess_descriptor_sets: [1]vk.DescriptorSet
g_postprocess_descriptor_set_layouts: [1]vk.DescriptorSetLayout

build_postprocess_pipelines :: proc(color_format: vk.Format) -> vk.Result {
  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = g_descriptor_pool,
    descriptorSetCount = len(g_postprocess_descriptor_set_layouts),
    pSetLayouts        = raw_data(g_postprocess_descriptor_set_layouts[:]),
  }
  vk.AllocateDescriptorSets(
    g_device,
    &alloc_info,
    raw_data(g_postprocess_descriptor_sets[:]),
  ) or_return

  count :: len(PostProcessEffectType)
  vert_module := create_shader_module(SHADER_POSTPROCESS_VERT) or_return
  frag_modules: [count]vk.ShaderModule
  descriptor_set_layouts: [count]vk.DescriptorSetLayout
  pipeline_infos: [count]vk.GraphicsPipelineCreateInfo
  rendering_infos: [count]vk.PipelineRenderingCreateInfoKHR
  push_constant_ranges: [count]vk.PushConstantRange
  set_layouts_arr: [count][1]vk.DescriptorSetLayout

  defer for module in frag_modules do vk.DestroyShaderModule(g_device, module, nil)
  defer vk.DestroyShaderModule(g_device, vert_module, nil)

  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
    blendEnable    = false,
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  color_formats := [?]vk.Format{color_format}
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
  vk.CreateDescriptorSetLayout(
    g_device,
    &layout_info,
    nil,
    &g_postprocess_descriptor_set_layouts[0],
  ) or_return

  // Create shader modules and layouts
  for effect_type, i in PostProcessEffectType {
    // Vertex shader
    // Fragment shader
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
    }

    // Descriptor set layout (shared for all)

    set_layouts_arr[i][0] = descriptor_set_layouts[i]

    #partial switch effect_type {
    case .BLUR:
      push_constant_ranges[i] = {
        stageFlags = {.FRAGMENT},
        size       = size_of(BlurEffect),
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
        module = frag_modules[i],
        pName = "main",
      },
    }

    flags: vk.PipelineCreateFlags =
      {.ALLOW_DERIVATIVES} if i == 0 else {.DERIVATIVE}

    pipeline_infos[i] = vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_infos[i],
      stageCount          = len(shader_stages),
      pStages             = raw_data(shader_stages[:]),
      pVertexInputState   = &vertex_input,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &color_blending,
      pDepthStencilState  = &depth_stencil_state,
      layout              = g_postprocess_pipeline_layouts[i],
      flags               = flags,
      basePipelineIndex   = 0,
    }
  }

  // Create all pipelines in one call
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    count,
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(g_postprocess_pipelines[:]),
  ) or_return

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
