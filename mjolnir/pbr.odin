package mjolnir

import "core:fmt"
import "core:log"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

PushConstant :: struct {
  world:               linalg.Matrix4f32,
  using textures:      MaterialTextures,
  metallic_value:      f32,
  roughness_value:     f32,
  emissive_value:      f32,
  environment_max_lod: f32,
  ibl_intensity:       f32,
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
  pipeline_layout:     vk.PipelineLayout,
  pipelines:           [SHADER_VARIANT_COUNT]vk.Pipeline,
  unlit_pipelines:     [UNLIT_SHADER_VARIANT_COUNT]vk.Pipeline,
  wireframe_pipelines: [UNLIT_SHADER_VARIANT_COUNT]vk.Pipeline,
  environment_map:     Handle,
  brdf_lut:            Handle,
  ibl_intensity:       f32,
}

renderer_main_build_pbr_pipeline :: proc(
  self: ^RendererMain,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  set_layouts := [?]vk.DescriptorSetLayout {
    g_camera_descriptor_set_layout, // set = 0
    g_lights_descriptor_set_layout, // set = 1
    g_textures_set_layout, // set = 2
    g_bindless_bone_buffer_set_layout, // set = 3
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(PushConstant),
  }
  vk.CreatePipelineLayout(
    g_device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &self.pipeline_layout,
  ) or_return
  pipeline_infos: [SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  spec_infos: [SHADER_VARIANT_COUNT]vk.SpecializationInfo
  configs: [SHADER_VARIANT_COUNT]ShaderConfig
  entries: [SHADER_VARIANT_COUNT][SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  shader_stages: [SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  vert_module := create_shader_module(SHADER_UBER_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_module := create_shader_module(SHADER_UBER_FRAG) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states_values),
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
  for mask in 0 ..< SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask
    configs[mask] = {
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
    shader_stages[mask] = [?]vk.PipelineShaderStageCreateInfo {
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
      stageCount          = len(shader_stages[mask]),
      pStages             = raw_data(shader_stages[mask][:]),
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
  shader_stages: [UNLIT_SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  vert_module := create_shader_module(SHADER_UNLIT_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_module := create_shader_module(SHADER_UNLIT_FRAG) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states_values),
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
    configs[mask] = {
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
    shader_stages[mask] = [2]vk.PipelineShaderStageCreateInfo {
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
      stageCount          = len(shader_stages[mask]),
      pStages             = raw_data(shader_stages[mask][:]),
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
  shader_stages: [UNLIT_SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  vert_module := create_shader_module(SHADER_UNLIT_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_module := create_shader_module(SHADER_UNLIT_FRAG) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states_values),
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
    polygonMode = .LINE,
    lineWidth   = 1.0,
    cullMode    = {}, // Disable culling for wireframe
    frontFace   = .COUNTER_CLOCKWISE,
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
    configs[mask] = {
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
    shader_stages[mask] = [?]vk.PipelineShaderStageCreateInfo {
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
      stageCount          = len(shader_stages[mask]),
      pStages             = raw_data(shader_stages[mask][:]),
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
    raw_data(self.wireframe_pipelines[:]),
  ) or_return
  return .SUCCESS
}

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
    return self.wireframe_pipelines[transmute(u32)material.features]
  }
  // Fallback
  return self.pipelines[0]
}

renderer_main_begin :: proc(
  target: RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = target.final,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = target.depth,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD, // Load existing depth from dedicated depth pre-pass
    storeOp     = .STORE,
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = {width = target.width, height = target.height}},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(target.height),
    width    = f32(target.width),
    height   = -f32(target.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = {width = target.width, height = target.height},
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

renderer_main_render :: proc(
  self: ^RendererMain,
  input: RenderInput,
  command_buffer: vk.CommandBuffer,
) -> int {
  descriptor_sets := [?]vk.DescriptorSet {
    g_camera_descriptor_sets[g_frame_index],
    g_lights_descriptor_sets[g_frame_index],
    g_textures_descriptor_set,
    g_bindless_bone_buffer_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  rendered_count := 0
  current_pipeline: vk.Pipeline = 0
  for _, batch_group in input.batches {
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
        // Calculate max LOD based on environment texture
        environment_texture :=
          resource.get(g_image_buffers, self.environment_map) or_else nil
        max_lod: f32 = 8.0 // Default fallback
        if environment_texture != nil {
          max_lod = calculate_mip_levels(environment_texture.width, environment_texture.height) - 1.0
        }
        push_constant := PushConstant {
          world               = node.transform.world_matrix,
          textures            = texture_indices,
          metallic_value      = material.metallic_value,
          roughness_value     = material.roughness_value,
          emissive_value      = material.emissive_value,
          environment_max_lod = max_lod,
          ibl_intensity       = self.ibl_intensity,
        }
        vk.CmdPushConstants(
          command_buffer,
          self.pipeline_layout,
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
          vk.CmdBindVertexBuffers(
            command_buffer,
            1,
            1,
            &mesh_skinning.skin_buffer.buffer,
            &offset,
          )
        }
        vk.CmdBindIndexBuffer(
          command_buffer,
          mesh.index_buffer.buffer,
          0,
          .UINT32,
        )
        vk.CmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0)
        rendered_count += 1
      }
    }
  }
  return rendered_count
}

renderer_main_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
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
  self.environment_map, environment_map =
    create_hdr_texture_from_path_with_mips(
      "assets/Cannon_Exterior.hdr",
    ) or_return
  brdf_lut: ^ImageBuffer
  self.brdf_lut, brdf_lut = create_texture_from_data(
    #load("assets/lut_ggx.png"),
  ) or_return
  self.ibl_intensity = 1.0 // Default IBL intensity
  return .SUCCESS
}

renderer_main_deinit :: proc(self: ^RendererMain) {
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  for p in self.pipelines do vk.DestroyPipeline(g_device, p, nil)
  for p in self.unlit_pipelines do vk.DestroyPipeline(g_device, p, nil)
  for p in self.wireframe_pipelines do vk.DestroyPipeline(g_device, p, nil)
}

populate_render_batches :: proc(ctx: ^BatchingContext) {
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
      batch_data: ^BatchData
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
