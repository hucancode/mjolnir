package mjolnir

import linalg "core:math/linalg"
import "geometry"
import vk "vendor:vulkan"

SHADOW_FEATURE_SKINNING :: 1 << 0
SHADOW_SHADER_OPTION_COUNT :: 1
SHADOW_SHADER_VARIANT_COUNT :: 1 << SHADOW_SHADER_OPTION_COUNT

ShadowShaderConfig :: struct {
  is_skinned: b32,
}

// Encapsulated shadow pipeline structure
PipelineShadow :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipelines:       [SHADOW_SHADER_VARIANT_COUNT]vk.Pipeline,
}

pipeline_shadow_deinit :: proc(pipeline: ^PipelineShadow) {
  if pipeline == nil do return

  for &p in pipeline.pipelines {
    vk.DestroyPipeline(g_device, p, nil)
    p = 0
  }
  vk.DestroyPipelineLayout(g_device, pipeline.pipeline_layout, nil)
  pipeline.pipeline_layout = 0
}

SHADER_SHADOW_VERT :: #load("shader/shadow/vert.spv")

pipeline_shadow_init :: proc(
  pipeline: ^PipelineShadow,
  camera_descriptor_set_layout: vk.DescriptorSetLayout,
  skinning_descriptor_set_layout: vk.DescriptorSetLayout,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  set_layouts := [?]vk.DescriptorSetLayout {
    camera_descriptor_set_layout,
    skinning_descriptor_set_layout,
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    size       = size_of(linalg.Matrix4f32),
  }
  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = len(set_layouts),
    pSetLayouts            = raw_data(set_layouts[:]),
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }
  vk.CreatePipelineLayout(
    g_device,
    &pipeline_layout_info,
    nil,
    &pipeline.pipeline_layout,
  ) or_return

  vert_module := create_shader_module(SHADER_SHADOW_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)

  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states_values)),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    lineWidth               = 1.0,
    depthBiasEnable         = true,
    depthBiasConstantFactor = 1.25,
    depthBiasClamp          = 0.0,
    depthBiasSlopeFactor    = 1.75,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    depthAttachmentFormat = depth_format,
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.SIMPLE_VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.SIMPLE_VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  pipeline_infos: [SHADOW_SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  configs: [SHADOW_SHADER_VARIANT_COUNT]ShadowShaderConfig
  entries: [SHADOW_SHADER_VARIANT_COUNT][SHADOW_SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  spec_infos: [SHADOW_SHADER_VARIANT_COUNT]vk.SpecializationInfo
  shader_stages: [SHADOW_SHADER_VARIANT_COUNT][1]vk.PipelineShaderStageCreateInfo

  for features in 0 ..< SHADOW_SHADER_VARIANT_COUNT {
    configs[features] = ShadowShaderConfig {
      is_skinned = (features & SHADOW_FEATURE_SKINNING) != 0,
    }
    entries[features] = [SHADOW_SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
      {
        constantID = 0,
        offset = u32(offset_of(ShadowShaderConfig, is_skinned)),
        size = size_of(b32),
      },
    }
    spec_infos[features] = vk.SpecializationInfo {
      mapEntryCount = len(entries[features]),
      pMapEntries   = raw_data(entries[features][:]),
      dataSize      = size_of(ShadowShaderConfig),
      pData         = &configs[features],
    }
    shader_stages[features] = [1]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[features],
      },
    }
    pipeline_infos[features] = vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages[features]),
      pStages             = raw_data(shader_stages[features][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = pipeline.pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(pipeline.pipelines[:]),
  ) or_return
  return .SUCCESS
}


// Getter functions for accessing pipeline components
pipeline_shadow_get_pipeline :: proc(pipeline: ^PipelineShadow, features: ShaderFeatureSet) -> vk.Pipeline {
  return pipeline.pipelines[transmute(u32)features]
}

pipeline_shadow_get_layout :: proc(pipeline: ^PipelineShadow) -> vk.PipelineLayout {
  return pipeline.pipeline_layout
}
