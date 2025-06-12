package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:time"
import "geometry"
import "resource"
import vk "vendor:vulkan"

MAX_LIGHTS :: 10
SHADOW_MAP_SIZE :: 512
MAX_SHADOW_MAPS :: MAX_LIGHTS
MAX_SCENE_UNIFORMS :: 16

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

SingleLightUniform :: struct {
  view_proj:  linalg.Matrix4f32,
  color:      linalg.Vector4f32,
  position:   linalg.Vector4f32,
  direction:  linalg.Vector4f32,
  kind:       enum u32 {
    POINT       = 0,
    DIRECTIONAL = 1,
    SPOT        = 2,
  },
  angle:      f32, // For spotlight: cone angle
  radius:     f32, // For point/spot: attenuation radius
  has_shadow: b32,
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

push_light :: proc(self: ^SceneLightUniform, light: SingleLightUniform) {
  if self.light_count < MAX_LIGHTS {
    self.lights[self.light_count] = light
    self.light_count += 1
  }
}

clear_lights :: proc(self: ^SceneLightUniform) {
  self.light_count = 0
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
  frames:                            [MAX_FRAMES_IN_FLIGHT]struct {
    camera_uniform:        DataBuffer(SceneUniform),
    light_uniform:         DataBuffer(SceneLightUniform),
    camera_descriptor_set: vk.DescriptorSet,
    main_pass_image:       ImageBuffer,
    shadow_maps:           [MAX_SHADOW_MAPS]ImageBuffer,
    cube_shadow_maps:      [MAX_SHADOW_MAPS]CubeImageBuffer,
  },
  frame_index:                       u32,
  camera_descriptor_set_layout:      vk.DescriptorSetLayout,
  environment_descriptor_set_layout: vk.DescriptorSetLayout,
  texture_descriptor_set_layout:     vk.DescriptorSetLayout,
  skinning_descriptor_set_layout:    vk.DescriptorSetLayout,
  pipeline_layout:                   vk.PipelineLayout,
  pipelines:                         [SHADER_VARIANT_COUNT]vk.Pipeline,
  unlit_pipelines:                   [UNLIT_SHADER_VARIANT_COUNT]vk.Pipeline,
  environment_descriptor_set:        vk.DescriptorSet,
  depth_buffer:                      ImageBuffer,
  // managed by pool, so we don't need to deinit
  environment_map:                   ^ImageBuffer,
  brdf_lut:                          ^ImageBuffer,
}

renderer_main_build_pbr_pipeline :: proc(
  self: ^RendererMain,
  color_format: vk.Format,
  depth_format: vk.Format,
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
    g_device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(texture_bindings)),
      pBindings = raw_data(texture_bindings),
    },
    nil,
    &self.texture_descriptor_set_layout,
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
    g_device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(skinning_bindings)),
      pBindings = raw_data(skinning_bindings),
    },
    nil,
    &self.skinning_descriptor_set_layout,
  ) or_return
  environment_bindings := []vk.DescriptorSetLayoutBinding {
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
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(environment_bindings)),
      pBindings = raw_data(environment_bindings),
    },
    nil,
    &self.environment_descriptor_set_layout,
  ) or_return
  set_layouts := [?]vk.DescriptorSetLayout {
    self.camera_descriptor_set_layout, // set = 0
    self.texture_descriptor_set_layout, // set = 1
    self.skinning_descriptor_set_layout, // set = 2
    self.environment_descriptor_set_layout, // set = 3
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    size       = size_of(linalg.Matrix4f32),
  }
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
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

renderer_main_get_pipeline :: proc(
  self: ^RendererMain,
  material: ^Material,
) -> vk.Pipeline {
  if material.is_lit {
    return self.pipelines[transmute(u32)material.features]
  }
  return self.unlit_pipelines[transmute(u32)material.features]
}

render_main_pass :: proc(
  self: ^RendererMain,
  command_buffer: vk.CommandBuffer,
  camera_frustum: geometry.Frustum,
  swapchain_extent: vk.Extent2D,
) -> vk.Result {
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = renderer_get_main_pass_view(self),
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = self.depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = swapchain_extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(swapchain_extent.height),
    width    = f32(swapchain_extent.width),
    height   = -f32(swapchain_extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = swapchain_extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  return .SUCCESS
}

render_single_node :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^RenderMeshesContext)(cb_context)
  #partial switch data in node.attachment {
  case MeshAttachment:
    mesh := resource.get(g_meshes, data.handle)
    if mesh == nil {
      return true
    }
    material := resource.get(g_materials, data.material)
    if material == nil {
      return true
    }
    world_aabb := geometry.aabb_transform(
      mesh.aabb,
      node.transform.world_matrix,
    )
    if !geometry.frustum_test_aabb(&ctx.camera_frustum, world_aabb) {
      return true
    }
    pipeline := renderer_main_get_pipeline(&ctx.engine.main, material)
    layout := ctx.engine.main.pipeline_layout
    descriptor_sets := [?]vk.DescriptorSet {
      renderer_get_camera_descriptor_set(&ctx.engine.main), // set 0
      material.texture_descriptor_set, // set 1
      material.skinning_descriptor_sets[g_frame_index], // set 2
      ctx.engine.main.environment_descriptor_set, // set 3
    }
    offsets := [1]u32{0}
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      &node.transform.world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    mesh_skinning, mesh_has_skin := &mesh.skinning.?
    node_skinning, node_has_skin := data.skinning.?
    if mesh_has_skin && node_has_skin {
      material_update_bone_buffer(
        material,
        node_skinning.bone_buffers[g_frame_index].buffer,
        vk.DeviceSize(node_skinning.bone_buffers[g_frame_index].bytes_count),
        g_frame_index,
      )
      vk.CmdBindVertexBuffers(
        ctx.command_buffer,
        1,
        1,
        &mesh_skinning.skin_buffer.buffer,
        &offset,
      )
    }
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.rendered_count^ += 1
  }
  return true
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
  scene_uniform := SceneUniform {
    view       = geometry.calculate_view_matrix(render_camera),
    projection = geometry.calculate_projection_matrix(render_camera),
    time       = f32(
      time.duration_seconds(time.since(engine.start_timestamp)),
    ),
  }
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
  data_buffer_write(renderer_get_camera_uniform(&engine.main), &scene_uniform)
  rendered_count: u32 = 0
  render_meshes_ctx := RenderMeshesContext {
    engine         = engine,
    command_buffer = command_buffer,
    camera_frustum = camera_frustum,
    rendered_count = &rendered_count,
  }
  scene_traverse_linear(&engine.scene, &render_meshes_ctx, render_single_node)
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
  depth_image_init(&self.depth_buffer, width, height, depth_format) or_return
  _, self.environment_map = create_hdr_texture_from_path(
    "assets/teutonic_castle_moat_4k.hdr",
  ) or_return
  _, self.brdf_lut = create_texture_from_path("assets/lut_ggx.png") or_return
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.environment_descriptor_set_layout,
    },
    &self.environment_descriptor_set,
  ) or_return
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.environment_descriptor_set,
      dstBinding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{
        sampler = g_linear_repeat_sampler,
        imageView = self.environment_map.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.environment_descriptor_set,
      dstBinding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{
        sampler = g_linear_repeat_sampler,
        imageView = self.brdf_lut.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  }
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
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
        descriptorType = .UNIFORM_BUFFER_DYNAMIC,
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
  self.frame_index = 0
  return .SUCCESS
}

renderer_main_deinit :: proc(self: ^RendererMain) {
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.camera_descriptor_set_layout,
    nil,
  )
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.environment_descriptor_set_layout,
    nil,
  )
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.texture_descriptor_set_layout,
    nil,
  )
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.skinning_descriptor_set_layout,
    nil,
  )
  for &frame in self.frames {
    data_buffer_deinit(&frame.camera_uniform)
    data_buffer_deinit(&frame.light_uniform)
  }
  for p in self.pipelines do vk.DestroyPipeline(g_device, p, nil)
  for p in self.unlit_pipelines do vk.DestroyPipeline(g_device, p, nil)
  renderer_main_deinit_images(self)
}

renderer_main_init_images :: proc(
  self: ^RendererMain,
  width: u32,
  height: u32,
  color_format: vk.Format,
) -> vk.Result {
  depth_image_init(&self.depth_buffer, width, height) or_return
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

renderer_get_main_pass_image :: proc(self: ^RendererMain) -> vk.Image {
  return self.frames[self.frame_index].main_pass_image.image
}

renderer_get_main_pass_view :: proc(self: ^RendererMain) -> vk.ImageView {
  return self.frames[self.frame_index].main_pass_image.view
}

renderer_get_camera_uniform :: proc(
  self: ^RendererMain,
) -> ^DataBuffer(SceneUniform) {
  return &self.frames[self.frame_index].camera_uniform
}

renderer_get_light_uniform :: proc(
  self: ^RendererMain,
) -> ^DataBuffer(SceneLightUniform) {
  return &self.frames[self.frame_index].light_uniform
}

renderer_get_shadow_map :: proc(
  self: ^RendererMain,
  light_idx: int,
) -> ^ImageBuffer {
  return &self.frames[self.frame_index].shadow_maps[light_idx]
}

renderer_get_cube_shadow_map :: proc(
  self: ^RendererMain,
  light_idx: int,
) -> ^CubeImageBuffer {
  return &self.frames[self.frame_index].cube_shadow_maps[light_idx]
}

renderer_get_camera_descriptor_set :: proc(
  self: ^RendererMain,
) -> vk.DescriptorSet {
  return self.frames[self.frame_index].camera_descriptor_set
}
