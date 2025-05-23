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
shadow_pipeline_layout: vk.PipelineLayout
shadow_pipelines: [SHADOW_SHADER_VARIANT_COUNT]vk.Pipeline

SHADER_SHADOW_VERT :: #load("shader/shadow/vert.spv")

build_shadow_pipelines :: proc(
  ctx: ^VulkanContext,
  depth_format: vk.Format,
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
    ctx.vkd,
    &pipeline_layout_info,
    nil,
    &shadow_pipeline_layout,
  ) or_return
  vert_module := create_shader_module(ctx, SHADER_SHADOW_VERT) or_return
  defer vk.DestroyShaderModule(ctx.vkd, vert_module, nil)

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
  for features in 0 ..< SHADOW_SHADER_VARIANT_COUNT {
    config := ShadowShaderConfig {
      is_skinned = (features & SHADOW_FEATURE_SKINNING) != 0,
    }
    entries := [1]vk.SpecializationMapEntry {
      {
        constantID = 0,
        offset = u32(offset_of(ShadowShaderConfig, is_skinned)),
        size = size_of(b32),
      },
    }
    spec_info := vk.SpecializationInfo {
      mapEntryCount = len(entries),
      pMapEntries   = raw_data(entries[:]),
      dataSize      = size_of(ShadowShaderConfig),
      pData         = &config,
    }
    shader_stages := [?]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_info,
      },
    }
    pipeline_infos[features] = vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages),
      pStages             = raw_data(shader_stages[:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = shadow_pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    ctx.vkd,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(shadow_pipelines[:]),
  ) or_return
  return .SUCCESS
}
