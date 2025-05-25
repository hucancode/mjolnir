package mjolnir

import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_FEATURE_SKINNING :: 1 << 0
SHADER_FEATURE_ALBEDO_TEXTURE       :: 1 << 1
SHADER_FEATURE_METALLIC_ROUGHNESS_TEXTURE :: 1 << 2
SHADER_FEATURE_NORMAL_TEXTURE       :: 1 << 3
SHADER_FEATURE_DISPLACEMENT_TEXTURE :: 1 << 4
SHADER_FEATURE_EMISSIVE_TEXTURE     :: 1 << 5

SHADER_OPTION_COUNT :: 6
SHADER_VARIANT_COUNT :: 1 << SHADER_OPTION_COUNT

// Specialization constant struct (must match shader)
ShaderConfig :: struct {
    is_skinned:             b32,
    has_albedo_texture:     b32,
    has_metallic_roughness_texture: b32,
    has_normal_texture:     b32,
    has_displacement_texture:b32,
    has_emissive_texture:   b32,
}

camera_descriptor_set_layout: vk.DescriptorSetLayout
environment_descriptor_set_layout: vk.DescriptorSetLayout

// material set layouts only account for textures and bones features
texture_descriptor_set_layout: vk.DescriptorSetLayout
skinning_descriptor_set_layout: vk.DescriptorSetLayout
pipeline_layout: vk.PipelineLayout
pipelines: [SHADER_VARIANT_COUNT]vk.Pipeline

// Shader binaries (should point to your uber shader)
SHADER_UBER_VERT :: #load("shader/uber/vert.spv")
SHADER_UBER_FRAG :: #load("shader/uber/frag.spv")

build_3d_pipelines :: proc(
  ctx: ^VulkanContext,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> vk.Result {
  bindings_main := [?]vk.DescriptorSetLayoutBinding {
    {   // Scene Uniforms (view, proj, time)
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER_DYNAMIC,
      descriptorCount = 1,
      stageFlags      = {.VERTEX, .FRAGMENT},
    },
    {   // Light Uniforms
      binding         = 1,
      descriptorType  = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Shadow Maps
      binding         = 2,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      stageFlags      = {.FRAGMENT},
    },
    {   // Cube Shadow Maps
      binding         = 3,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      stageFlags      = {.FRAGMENT},
    },
  }
  layout_info_main := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings_main),
    pBindings    = raw_data(bindings_main[:]),
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &layout_info_main,
    nil,
    &camera_descriptor_set_layout,
  ) or_return
  pipeline_infos: [SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  spec_infos: [SHADER_VARIANT_COUNT]vk.SpecializationInfo
  configs: [SHADER_VARIANT_COUNT]ShaderConfig
  entries: [SHADER_VARIANT_COUNT][SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  shader_stages_arr: [SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo

  vert_module := create_shader_module(ctx, SHADER_UBER_VERT) or_return
  defer vk.DestroyShaderModule(ctx.vkd, vert_module, nil)
  frag_module := create_shader_module(ctx, SHADER_UBER_FRAG) or_return
  defer vk.DestroyShaderModule(ctx.vkd, frag_module, nil)

  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states_values)),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
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
    cullMode    = {.BACK},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
  }
  blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }
  color_formats := [?]vk.Format{target_color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = .D32_SFLOAT,
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  texture_bindings := []vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 3,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 4,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 5,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(texture_bindings)),
      pBindings = raw_data(texture_bindings),
    },
    nil,
    &texture_descriptor_set_layout,
  ) or_return
  skinning_bindings := []vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(skinning_bindings)),
      pBindings = raw_data(skinning_bindings),
    },
    nil,
    &skinning_descriptor_set_layout,
  ) or_return

  // Environment map descriptor set layout
  environment_bindings := []vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(environment_bindings)),
      pBindings = raw_data(environment_bindings),
    },
    nil,
    &environment_descriptor_set_layout,
  ) or_return

  set_layouts := [?]vk.DescriptorSetLayout {
    camera_descriptor_set_layout, // set = 0
    texture_descriptor_set_layout, // set = 1
    skinning_descriptor_set_layout, // set = 2
    environment_descriptor_set_layout, // set = 3
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
    &pipeline_layout,
  ) or_return
  for features in 0 ..< SHADER_VARIANT_COUNT {
      configs[features] = ShaderConfig {
        is_skinned              = (features & SHADER_FEATURE_SKINNING) != 0,
        has_albedo_texture      = (features & SHADER_FEATURE_ALBEDO_TEXTURE) != 0,
        has_metallic_roughness_texture = (features & SHADER_FEATURE_METALLIC_ROUGHNESS_TEXTURE) != 0,
        has_normal_texture      = (features & SHADER_FEATURE_NORMAL_TEXTURE) != 0,
        has_displacement_texture= (features & SHADER_FEATURE_DISPLACEMENT_TEXTURE) != 0,
        has_emissive_texture    = (features & SHADER_FEATURE_EMISSIVE_TEXTURE) != 0,
      }
      entries[features] = [SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
        {
          constantID = 0,
          offset = u32(offset_of(ShaderConfig, is_skinned)),
          size = size_of(b32),
        },
        {
          constantID = 1,
          offset = u32(offset_of(ShaderConfig, has_albedo_texture)),
          size = size_of(b32),
        },
        {
          constantID = 2,
          offset = u32(offset_of(ShaderConfig, has_metallic_roughness_texture)),
          size = size_of(b32),
        },
        {
          constantID = 3,
          offset = u32(offset_of(ShaderConfig, has_normal_texture)),
          size = size_of(b32),
        },
        {
          constantID = 4,
          offset = u32(offset_of(ShaderConfig, has_displacement_texture)),
          size = size_of(b32),
        },
        {
          constantID = 5,
          offset = u32(offset_of(ShaderConfig, has_emissive_texture)),
          size = size_of(b32),
        },
      }
    spec_infos[features] = vk.SpecializationInfo {
      mapEntryCount = len(entries[features]),
      pMapEntries   = raw_data(entries[features][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[features],
    }
    shader_stages_arr[features] = [?]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[features],
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[features],
      },
    }
    fmt.printfln(
      "Creating pipeline for features: %08b with config %v with vertex input %v",
      features,
      configs[features],
      vertex_input_info,
    )
    pipeline_infos[features] = vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages_arr[features]),
      pStages             = raw_data(shader_stages_arr[features][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &blending,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    ctx.vkd,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(pipelines[:]),
  ) or_return
  return .SUCCESS
}

UNLIT_SHADER_OPTION_COUNT :: 2
UNLIT_SHADER_VARIANT_COUNT :: 1 << UNLIT_SHADER_OPTION_COUNT

unlit_pipelines: [SHADER_VARIANT_COUNT]vk.Pipeline

SHADER_UNLIT_VERT :: #load("shader/unlit/vert.spv")
SHADER_UNLIT_FRAG :: #load("shader/unlit/frag.spv")

build_3d_unlit_pipelines :: proc(
  ctx: ^VulkanContext,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> vk.Result {
  pipeline_infos: [UNLIT_SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  spec_infos: [UNLIT_SHADER_VARIANT_COUNT]vk.SpecializationInfo
  configs: [UNLIT_SHADER_VARIANT_COUNT]ShaderConfig
  entries: [UNLIT_SHADER_VARIANT_COUNT][UNLIT_SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  shader_stages_arr: [UNLIT_SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo

  vert_module := create_shader_module(ctx, SHADER_UNLIT_VERT) or_return
  defer vk.DestroyShaderModule(ctx.vkd, vert_module, nil)
  frag_module := create_shader_module(ctx, SHADER_UNLIT_FRAG) or_return
  defer vk.DestroyShaderModule(ctx.vkd, frag_module, nil)

  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states_values)),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
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
    cullMode    = {.BACK},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
  }
  blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }
  color_formats := [?]vk.Format{target_color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = .D32_SFLOAT,
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  for features in 0 ..< UNLIT_SHADER_VARIANT_COUNT {
      configs[features] = ShaderConfig {
        is_skinned              = (features & SHADER_FEATURE_SKINNING) != 0,
        has_albedo_texture      = (features & SHADER_FEATURE_ALBEDO_TEXTURE) != 0,
      }
      entries[features] = [UNLIT_SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
        {
          constantID = 0,
          offset = u32(offset_of(ShaderConfig, is_skinned)),
          size = size_of(b32),
        },
        {
          constantID = 1,
          offset = u32(offset_of(ShaderConfig, has_albedo_texture)),
          size = size_of(b32),
        },
      }
    spec_infos[features] = vk.SpecializationInfo {
      mapEntryCount = len(entries[features]),
      pMapEntries   = raw_data(entries[features][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[features],
    }
    shader_stages_arr[features] = [?]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[features],
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[features],
      },
    }
    fmt.printfln(
      "Creating unlit pipeline for features: %08b with config %v with vertex input %v",
      features,
      configs[features],
      vertex_input_info,
    )
    pipeline_infos[features] = vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages_arr[features]),
      pStages             = raw_data(shader_stages_arr[features][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &blending,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    ctx.vkd,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(unlit_pipelines[:]),
  ) or_return
  return .SUCCESS
}
