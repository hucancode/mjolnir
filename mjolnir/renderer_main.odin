package mjolnir

import "core:fmt"
import "core:log"
import linalg "core:math/linalg"
import "core:mem"
import "core:time"
import "geometry"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

MAX_LIGHTS :: 10
SHADOW_MAP_SIZE :: 512
MAX_SHADOW_MAPS :: MAX_LIGHTS
MAX_SCENE_UNIFORMS :: 16
MAX_TEXTURES :: 50

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

PushConstant :: struct {
  world:           linalg.Matrix4f32,
  using textures:  MaterialTextures,
  metallic_value:  f32,
  roughness_value: f32,
  emissive_value:  f32,
  padding:         f32,
}

SingleLightUniform :: struct {
  view_proj:  linalg.Matrix4f32, // 64 bytes
  color:      linalg.Vector4f32, // 16 bytes
  position:   linalg.Vector4f32, // 16 bytes
  direction:  linalg.Vector4f32, // 16 bytes
  kind:       LightKind, // 4 bytes
  angle:      f32, // 4 bytes (spot light angle)
  radius:     f32, // 4 bytes (point/spot light radius)
  has_shadow: b32, // 4 bytes
}

SceneUniform :: struct {
  view:       linalg.Matrix4f32,
  projection: linalg.Matrix4f32,
  time:       f32,
  padding:    [3]f32,
}

SceneLightUniform :: struct {
  lights:      [MAX_LIGHTS]SingleLightUniform,
  light_count: u32,
  padding:     [3]u32,
}

ShaderFeatures :: enum {
  SKINNING                   = 0,
  ALBEDO_TEXTURE             = 1,
  METALLIC_ROUGHNESS_TEXTURE = 2,
  NORMAL_TEXTURE             = 3,
  DISPLACEMENT_TEXTURE       = 4,
  EMISSIVE_TEXTURE           = 5,
}
ShaderFeatureSet :: bit_set[ShaderFeatures;u32]
SHADER_OPTION_COUNT: u32 : len(ShaderFeatures)
SHADER_VARIANT_COUNT: u32 : 1 << SHADER_OPTION_COUNT

ShaderConfig :: struct {
  is_skinned:                     b32,
  has_albedo_texture:             b32,
  has_metallic_roughness_texture: b32,
  has_normal_texture:             b32,
  has_displacement_texture:       b32,
  has_emissive_texture:           b32,
}

UNLIT_SHADER_OPTION_COUNT :: 2
UNLIT_SHADER_VARIANT_COUNT: u32 : 1 << UNLIT_SHADER_OPTION_COUNT

SHADER_UBER_VERT :: #load("shader/uber/vert.spv")
SHADER_UBER_FRAG :: #load("shader/uber/frag.spv")
SHADER_UNLIT_VERT :: #load("shader/unlit/vert.spv")
SHADER_UNLIT_FRAG :: #load("shader/unlit/frag.spv")

RendererMain :: struct {
  frames:                       [MAX_FRAMES_IN_FLIGHT]struct {
    camera_uniform:        DataBuffer(SceneUniform),
    light_uniform:         DataBuffer(SceneLightUniform),
    camera_descriptor_set: vk.DescriptorSet,
    main_pass_image:       ImageBuffer,
    shadow_maps:           [MAX_SHADOW_MAPS]ImageBuffer,
    cube_shadow_maps:      [MAX_SHADOW_MAPS]CubeImageBuffer,
  },
  camera_descriptor_set_layout: vk.DescriptorSetLayout,
  pipeline_layout:              vk.PipelineLayout,
  pipelines:                    [SHADER_VARIANT_COUNT]vk.Pipeline,
  unlit_pipelines:              [UNLIT_SHADER_VARIANT_COUNT]vk.Pipeline,
  wireframe_unlit_pipelines:    [UNLIT_SHADER_VARIANT_COUNT]vk.Pipeline,
  environment_map:              Handle,
  brdf_lut:                     Handle,
}

renderer_main_build_pbr_pipeline :: proc(
  self: ^RendererMain,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  bindings_main := [?]vk.DescriptorSetLayoutBinding {
    {   // Scene Uniforms (view, proj, time)
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER,
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
    g_device,
    &layout_info_main,
    nil,
    &self.camera_descriptor_set_layout,
  ) or_return
  pipeline_infos: [SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  spec_infos: [SHADER_VARIANT_COUNT]vk.SpecializationInfo
  configs: [SHADER_VARIANT_COUNT]ShaderConfig
  entries: [SHADER_VARIANT_COUNT][SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  shader_stages_arr: [SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  vert_module := create_shader_module(SHADER_UBER_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_module := create_shader_module(SHADER_UBER_FRAG) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
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
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    lineWidth               = 1.0,
    depthBiasEnable         = true,
    // TODO: I don't know why these values are negative, but they work
    depthBiasConstantFactor = -0.1,
    depthBiasSlopeFactor    = -0.2,
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
    depthWriteEnable = false, // Don't write depth in main pass after depth pre-pass
    depthCompareOp   = .LESS_OR_EQUAL, // Use LESS_OR_EQUAL to handle floating point precision
  }
  color_formats := [?]vk.Format{color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = depth_format,
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
  // Only keep camera, bindless textures, bindless samplers, and skinning layouts
  set_layouts := [?]vk.DescriptorSetLayout {
    self.camera_descriptor_set_layout, // set = 0
    g_bindless_textures_layout, // set = 1
    g_bindless_samplers_layout, // set = 2
    g_bindless_bone_buffer_set_layout, // set = 3
  }
  push_constant_range := [?]vk.PushConstantRange {
    {stageFlags = {.VERTEX, .FRAGMENT}, size = size_of(PushConstant)},
  }
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
      pushConstantRangeCount = len(push_constant_range),
      pPushConstantRanges = raw_data(push_constant_range[:]),
    },
    nil,
    &self.pipeline_layout,
  ) or_return
  for mask in 0 ..< SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask
    configs[mask] = ShaderConfig {
      is_skinned                     = .SKINNING in features,
      has_albedo_texture             = .ALBEDO_TEXTURE in features,
      has_metallic_roughness_texture = .METALLIC_ROUGHNESS_TEXTURE in features,
      has_normal_texture             = .NORMAL_TEXTURE in features,
      has_displacement_texture       = .DISPLACEMENT_TEXTURE in features,
      has_emissive_texture           = .EMISSIVE_TEXTURE in features,
    }
    entries[mask] = [SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
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
    spec_infos[mask] = {
      mapEntryCount = len(entries[mask]),
      pMapEntries   = raw_data(entries[mask][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[mask],
    }
    shader_stages_arr[mask] = [?]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
    }
    log.infof(
      "Creating pipeline for features: %v with config %v with vertex input %v",
      features,
      configs[mask],
      vertex_input_info,
    )
    pipeline_infos[mask] = {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages_arr[mask]),
      pStages             = raw_data(shader_stages_arr[mask][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &blending,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = self.pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.pipelines[:]),
  ) or_return
  return .SUCCESS
}

renderer_main_build_unlit_pipeline :: proc(
  self: ^RendererMain,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> vk.Result {
  pipeline_infos: [UNLIT_SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  spec_infos: [UNLIT_SHADER_VARIANT_COUNT]vk.SpecializationInfo
  configs: [UNLIT_SHADER_VARIANT_COUNT]ShaderConfig
  entries: [UNLIT_SHADER_VARIANT_COUNT][UNLIT_SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  shader_stages_arr: [UNLIT_SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  vert_module := create_shader_module(SHADER_UNLIT_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_module := create_shader_module(SHADER_UNLIT_FRAG) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
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
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    lineWidth               = 1.0,
    depthBiasEnable         = true,
    // TODO: I don't know why these values are negative, but they work
    depthBiasConstantFactor = -0.1,
    depthBiasSlopeFactor    = -0.2,
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
    depthWriteEnable = false,
    depthCompareOp   = .LESS_OR_EQUAL,
  }
  color_formats := [?]vk.Format{target_color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = target_depth_format,
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
  for mask in 0 ..< UNLIT_SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask
    configs[mask] = ShaderConfig {
      is_skinned         = .SKINNING in features,
      has_albedo_texture = .ALBEDO_TEXTURE in features,
    }
    entries[mask] = [UNLIT_SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
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
    spec_infos[mask] = {
      mapEntryCount = len(entries[mask]),
      pMapEntries   = raw_data(entries[mask][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[mask],
    }
    shader_stages_arr[mask] = [2]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
    }
    log.infof(
      "Creating unlit pipeline for features: %v with config %v with vertex input %v",
      features,
      configs[mask],
      vertex_input_info,
    )
    pipeline_infos[mask] = {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages_arr[mask]),
      pStages             = raw_data(shader_stages_arr[mask][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &blending,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = self.pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.unlit_pipelines[:]),
  ) or_return
  return .SUCCESS
}

renderer_main_build_wireframe_unlit_pipeline :: proc(
  self: ^RendererMain,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> vk.Result {
  pipeline_infos: [UNLIT_SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  spec_infos: [UNLIT_SHADER_VARIANT_COUNT]vk.SpecializationInfo
  configs: [UNLIT_SHADER_VARIANT_COUNT]ShaderConfig
  entries: [UNLIT_SHADER_VARIANT_COUNT][UNLIT_SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  shader_stages_arr: [UNLIT_SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  vert_module := create_shader_module(SHADER_UNLIT_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_module := create_shader_module(SHADER_UNLIT_FRAG) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
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
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode             = .LINE, // Key difference - wireframe mode
    cullMode                = {}, // Disable culling for wireframe
    frontFace               = .COUNTER_CLOCKWISE,
    lineWidth               = 1.0,
    depthBiasEnable         = true,
    // TODO: I don't know why these values are negative, but they work
    depthBiasConstantFactor = -0.1,
    depthBiasSlopeFactor    = -0.2,
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
    depthWriteEnable = true, // Wireframe objects write their own depth (skip depth pre-pass)
    depthCompareOp   = .LESS, // Use LESS since wireframe objects don't use depth pre-pass
  }

  color_formats := [?]vk.Format{target_color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = target_depth_format,
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
  for mask in 0 ..< UNLIT_SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask
    configs[mask] = ShaderConfig {
      is_skinned         = .SKINNING in features,
      has_albedo_texture = .ALBEDO_TEXTURE in features,
    }
    entries[mask] = [UNLIT_SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
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
    spec_infos[mask] = {
      mapEntryCount = len(entries[mask]),
      pMapEntries   = raw_data(entries[mask][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[mask],
    }
    shader_stages_arr[mask] = [2]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
    }
    log.infof(
      "Creating unlit pipeline for features: %v with config %v with vertex input %v",
      features,
      configs[mask],
      vertex_input_info,
    )
    pipeline_infos[mask] = {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages_arr[mask]),
      pStages             = raw_data(shader_stages_arr[mask][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &blending,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = self.pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.wireframe_unlit_pipelines[:]),
  ) or_return
  return .SUCCESS
}

// Depth prepass pipeline builder has been moved to renderer_depth_prepass.odin

renderer_main_get_pipeline :: proc(
  self: ^RendererMain,
  material: ^Material,
) -> vk.Pipeline {
  switch material.type {
  case .PBR:
    return self.pipelines[transmute(u32)material.features]
  case .UNLIT:
    return self.unlit_pipelines[transmute(u32)material.features]
  case .WIREFRAME:
    // Wireframe materials always use unlit wireframe pipelines
    return self.wireframe_unlit_pipelines[transmute(u32)material.features]
  }
  // Fallback
  return self.pipelines[0]
}

// Depth prepass pipeline getter has been moved to renderer_depth_prepass.odin

renderer_main_begin :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.main.frames[g_frame_index].main_pass_image.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = engine.depth_prepass.depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD, // Load existing depth from dedicated depth pre-pass
    storeOp     = .STORE,
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
  scene_uniform := data_buffer_get(
    &engine.main.frames[g_frame_index].camera_uniform,
  )
  scene_uniform.view = geometry.calculate_view_matrix(engine.scene.camera)
  scene_uniform.projection = geometry.calculate_projection_matrix(
    engine.scene.camera,
  )
  scene_uniform.time = f32(
    time.duration_seconds(time.since(engine.start_timestamp)),
  )
  // Fill light_uniform from visible_lights
  light_uniform := data_buffer_get(
    &engine.main.frames[g_frame_index].light_uniform,
  )
  light_uniform.light_count = u32(len(engine.visible_lights[g_frame_index]))
  for light, i in engine.visible_lights[g_frame_index] {
    light_uniform.lights[i].kind = light.kind
    light_uniform.lights[i].color = linalg.Vector4f32 {
      light.color.x,
      light.color.y,
      light.color.z,
      1.0,
    }
    light_uniform.lights[i].radius = light.radius
    light_uniform.lights[i].angle = light.angle
    light_uniform.lights[i].has_shadow = b32(light.has_shadow)
    light_uniform.lights[i].position = light.position
    light_uniform.lights[i].direction = light.direction
    light_uniform.lights[i].view_proj = light.view * light.projection
  }
}

renderer_main_render :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  camera_frustum := geometry.camera_make_frustum(engine.scene.camera)
  temp_arena: mem.Arena
  temp_allocator_buffer := make([]u8, mem.Megabyte * 2) // 2MB should be enough for batching
  defer delete(temp_allocator_buffer)
  mem.arena_init(&temp_arena, temp_allocator_buffer)
  temp_allocator := mem.arena_allocator(&temp_arena)
  batching_ctx := BatchingContext {
    engine  = engine,
    frustum = camera_frustum,
    lights  = make([dynamic]SingleLightUniform, allocator = temp_allocator),
    batches = make(
      map[BatchKey][dynamic]BatchData,
      allocator = temp_allocator,
    ),
  }
  populate_render_batches(&batching_ctx)
  layout := engine.main.pipeline_layout
  descriptor_sets := [?]vk.DescriptorSet {
    engine.main.frames[g_frame_index].camera_descriptor_set, // set 0
    g_bindless_textures, // set 1
    g_bindless_samplers, // set 2
    g_bindless_bone_buffer_descriptor_set, // set 3
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    layout,
    0,
    u32(len(descriptor_sets)),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  rendered_count := render_batched_meshes(
    &engine.main,
    &batching_ctx,
    command_buffer,
  )
  if mu.window(
    &engine.ui.ctx,
    "Main pass renderer",
    {40, 200, 300, 150},
    {.NO_CLOSE},
  ) {
    mu.label(&engine.ui.ctx, fmt.tprintf("Rendered %v", rendered_count))
    mu.label(
      &engine.ui.ctx,
      fmt.tprintf("Batches %v", len(batching_ctx.batches)),
    )
    mu.label(
      &engine.ui.ctx,
      fmt.tprintf("Lights %d", len(batching_ctx.lights)),
    )
  }
}

renderer_main_end :: proc(engine: ^Engine, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

// Add render-to-texture capability
render_to_texture :: proc(
  engine: ^Engine,
  color_view: vk.ImageView,
  depth_view: vk.ImageView,
  extent: vk.Extent2D,
  camera: Maybe(geometry.Camera) = nil,
) -> vk.Result {
  command_buffer := engine.command_buffers[g_frame_index]
  render_camera := camera.? or_else engine.scene.camera
  scene_uniform := data_buffer_get(
    &engine.main.frames[g_frame_index].camera_uniform,
  )
  scene_uniform.view = geometry.calculate_view_matrix(render_camera)
  scene_uniform.projection = geometry.calculate_projection_matrix(
    render_camera,
  )
  scene_uniform.time = f32(
    time.duration_seconds(time.since(engine.start_timestamp)),
  )
  camera_frustum := geometry.camera_make_frustum(render_camera)
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = color_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = depth_view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(extent.height),
    width    = f32(extent.width),
    height   = -f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  // Create temporary batching context for render-to-texture
  temp_arena: mem.Arena
  temp_buffer := make([]u8, mem.Megabyte)
  defer delete(temp_buffer)
  mem.arena_init(&temp_arena, temp_buffer)
  temp_allocator := mem.arena_allocator(&temp_arena)
  batching_ctx := BatchingContext {
    engine  = engine,
    frustum = camera_frustum,
    lights  = make([dynamic]SingleLightUniform, allocator = temp_allocator),
    batches = make(
      map[BatchKey][dynamic]BatchData,
      allocator = temp_allocator,
    ),
  }
  populate_render_batches(&batching_ctx)
  layout := engine.main.pipeline_layout
  descriptor_sets := [?]vk.DescriptorSet {
    engine.main.frames[g_frame_index].camera_descriptor_set, // set 0
    g_bindless_textures, // set 1
    g_bindless_samplers, // set 2
    g_bindless_bone_buffer_descriptor_set, // set 3
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    layout,
    0,
    u32(len(descriptor_sets)),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  render_batched_meshes(&engine.main, &batching_ctx, command_buffer)
  vk.CmdEndRenderingKHR(command_buffer)
  return .SUCCESS
}

renderer_main_init :: proc(
  self: ^RendererMain,
  width: u32,
  height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  renderer_main_build_pbr_pipeline(self, color_format, depth_format) or_return
  renderer_main_build_unlit_pipeline(
    self,
    color_format,
    depth_format,
  ) or_return
  renderer_main_build_wireframe_unlit_pipeline(
    self,
    color_format,
    depth_format,
  ) or_return
  environment_map: ^ImageBuffer
  self.environment_map, environment_map = create_hdr_texture_from_path(
    "assets/teutonic_castle.hdr",
  ) or_return
  brdf_lut: ^ImageBuffer
  self.brdf_lut, brdf_lut = create_texture_from_data(
    #load("assets/lut_ggx.png"),
  ) or_return
  for &frame in self.frames {
    frame.camera_uniform = create_host_visible_buffer(
      SceneUniform,
      (MAX_SCENE_UNIFORMS),
      {.UNIFORM_BUFFER},
    ) or_return
    frame.light_uniform = create_host_visible_buffer(
      SceneLightUniform,
      1,
      {.UNIFORM_BUFFER},
    ) or_return
    for i in 0 ..< MAX_SHADOW_MAPS {
      depth_image_init(
        &frame.shadow_maps[i],
        SHADOW_MAP_SIZE,
        SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
      cube_depth_texture_init(
        &frame.cube_shadow_maps[i],
        SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    vk.AllocateDescriptorSets(
      g_device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = g_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &self.camera_descriptor_set_layout,
      },
      &frame.camera_descriptor_set,
    ) or_return
    shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
    for i in 0 ..< MAX_SHADOW_MAPS {
      shadow_map_image_infos[i] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = frame.shadow_maps[i].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    cube_shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
    for i in 0 ..< MAX_SHADOW_MAPS {
      cube_shadow_map_image_infos[i] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = frame.cube_shadow_maps[i].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = frame.camera_descriptor_set,
        dstBinding = 0,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &{
          buffer = frame.camera_uniform.buffer,
          range = vk.DeviceSize(size_of(SceneUniform)),
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = frame.camera_descriptor_set,
        dstBinding = 1,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &{
          buffer = frame.light_uniform.buffer,
          range = vk.DeviceSize(size_of(SceneLightUniform)),
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = frame.camera_descriptor_set,
        dstBinding = 2,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = MAX_SHADOW_MAPS,
        pImageInfo = raw_data(shadow_map_image_infos[:]),
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = frame.camera_descriptor_set,
        dstBinding = 3,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = MAX_SHADOW_MAPS,
        pImageInfo = raw_data(cube_shadow_map_image_infos[:]),
      },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  }
  renderer_main_init_images(self, width, height, color_format)
  return .SUCCESS
}

renderer_main_deinit :: proc(self: ^RendererMain) {
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.camera_descriptor_set_layout,
    nil,
  )
  for &frame in self.frames {
    data_buffer_deinit(&frame.camera_uniform)
    data_buffer_deinit(&frame.light_uniform)
  }
  for p in self.pipelines do vk.DestroyPipeline(g_device, p, nil)
  for p in self.unlit_pipelines do vk.DestroyPipeline(g_device, p, nil)
  for p in self.wireframe_unlit_pipelines do vk.DestroyPipeline(g_device, p, nil)
  renderer_main_deinit_images(self)
}

renderer_main_init_images :: proc(
  self: ^RendererMain,
  width: u32,
  height: u32,
  color_format: vk.Format,
) -> vk.Result {
  for &frame in self.frames {
    frame.main_pass_image = malloc_image_buffer(
      width,
      height,
      color_format,
      .OPTIMAL,
      {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
      {.DEVICE_LOCAL},
    ) or_return
    frame.main_pass_image.view = create_image_view(
      frame.main_pass_image.image,
      color_format,
      {.COLOR},
    ) or_return
  }
  return .SUCCESS
}

renderer_main_deinit_images :: proc(self: ^RendererMain) {
  // depth buffer is now managed by depth_prepass renderer
  for &frame in self.frames {
    image_buffer_deinit(&frame.main_pass_image)
  }
}

renderer_recreate_images :: proc(
  self: ^RendererMain,
  new_format: vk.Format,
  new_extent: vk.Extent2D,
) -> vk.Result {
  vk.DeviceWaitIdle(g_device)
  renderer_main_deinit_images(self)
  renderer_main_init_images(
    self,
    new_extent.width,
    new_extent.height,
    new_format,
  ) or_return
  return .SUCCESS
}

populate_render_batches :: proc(ctx: ^BatchingContext) {
  for light in ctx.engine.visible_lights[g_frame_index] {
    light_uniform := SingleLightUniform {
      kind       = light.kind,
      color      = linalg.Vector4f32 {
        light.color.x,
        light.color.y,
        light.color.z,
        1.0,
      },
      radius     = light.radius,
      angle      = light.angle,
      has_shadow = b32(light.has_shadow),
      position   = light.position,
      direction  = light.direction,
      view_proj  = light.view * light.projection,
    }
    append(&ctx.lights, light_uniform)
  }
  for &entry in ctx.engine.scene.nodes.entries do if entry.active {
    node := &entry.item
    #partial switch data in node.attachment {
    case MeshAttachment:
      mesh := resource.get(g_meshes, data.handle)
      if mesh == nil do continue
      material := resource.get(g_materials, data.material)
      if material == nil do continue
      world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
      if !geometry.frustum_test_aabb(&ctx.frustum, world_aabb) do continue
      batch_key := BatchKey {
        features      = material.features,
        material_type = material.type,
      }
      batch_group, group_found := &ctx.batches[batch_key]
      if !group_found {
        ctx.batches[batch_key] = make([dynamic]BatchData, allocator = context.temp_allocator)
        batch_group = &ctx.batches[batch_key]
      }
      batch_data: ^BatchData = nil
      for &batch in batch_group {
        if batch.material_handle == data.material {
          batch_data = &batch
          break
        }
      }

      if batch_data == nil {
        new_batch := BatchData {
          material_handle = data.material,
          nodes           = make([dynamic]^Node, allocator = context.temp_allocator),
        }
        append(batch_group, new_batch)
        batch_data = &batch_group[len(batch_group) - 1]
      }

      append(&batch_data.nodes, node)
    }
  }
}

render_batched_meshes :: proc(
  self: ^RendererMain,
  ctx: ^BatchingContext,
  command_buffer: vk.CommandBuffer,
) -> int {
  rendered := 0
  layout := self.pipeline_layout
  current_pipeline: vk.Pipeline = 0
  for batch_key, batch_group in ctx.batches {
    sample_material := resource.get(
      g_materials,
      batch_group[0].material_handle,
    ) or_continue
    pipeline := renderer_main_get_pipeline(self, sample_material)
    if pipeline != current_pipeline {
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
      current_pipeline = pipeline
    }
    for batch_data in batch_group {
      material := resource.get(
        g_materials,
        batch_data.material_handle,
      ) or_continue
      for node in batch_data.nodes {
        mesh_attachment := node.attachment.(MeshAttachment)
        mesh := resource.get(g_meshes, mesh_attachment.handle) or_continue
        texture_indices: MaterialTextures = {
          albedo_index             = min(
            MAX_TEXTURES - 1,
            material.albedo.index,
          ),
          metallic_roughness_index = min(
            MAX_TEXTURES - 1,
            material.metallic_roughness.index,
          ),
          normal_index             = min(
            MAX_TEXTURES - 1,
            material.normal.index,
          ),
          displacement_index       = min(
            MAX_TEXTURES - 1,
            material.displacement.index,
          ),
          emissive_index           = min(
            MAX_TEXTURES - 1,
            material.emissive.index,
          ),
          environment_index        = min(
            MAX_TEXTURES - 1,
            self.environment_map.index,
          ),
          brdf_lut_index           = min(
            MAX_TEXTURES - 1,
            self.brdf_lut.index,
          ),
        }
        if node_skinning, node_has_skin := mesh_attachment.skinning.?;
           node_has_skin {
          texture_indices.bone_matrix_offset =
            node_skinning.bone_matrix_offset +
            g_frame_index * g_bone_matrix_slab.capacity
        }
        push_constant := PushConstant {
          world           = node.transform.world_matrix,
          textures        = texture_indices,
          metallic_value  = material.metallic_value,
          roughness_value = material.roughness_value,
          emissive_value  = material.emissive_value,
        }
        vk.CmdPushConstants(
          command_buffer,
          layout,
          {.VERTEX, .FRAGMENT},
          0,
          size_of(PushConstant),
          &push_constant,
        )
        offset: vk.DeviceSize = 0
        vk.CmdBindVertexBuffers(
          command_buffer,
          0,
          1,
          &mesh.vertex_buffer.buffer,
          &offset,
        )
        if mesh_skinning, mesh_has_skin := &mesh.skinning.?; mesh_has_skin {
          if node_skinning, node_has_skin := mesh_attachment.skinning.?;
             node_has_skin {
            vk.CmdBindVertexBuffers(
              command_buffer,
              1,
              1,
              &mesh_skinning.skin_buffer.buffer,
              &offset,
            )
          }
        }
        vk.CmdBindIndexBuffer(
          command_buffer,
          mesh.index_buffer.buffer,
          0,
          .UINT32,
        )
        vk.CmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0)
        rendered += 1
      }
    }
  }
  return rendered
}
