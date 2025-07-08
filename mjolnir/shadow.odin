package mjolnir

import "core:log"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_SHADOW_VERT :: #load("shader/shadow/vert.spv")

SHADOW_SHADER_OPTION_COUNT: u32 : 1 // Only SKINNING
SHADOW_SHADER_VARIANT_COUNT: u32 : 1 << SHADOW_SHADER_OPTION_COUNT

ShadowShaderConfig :: struct {
  is_skinned: b32,
}

RendererShadow :: struct {
  pipeline_layout:              vk.PipelineLayout,
  pipelines:                    [SHADOW_SHADER_VARIANT_COUNT]vk.Pipeline,
  camera_descriptor_set_layout: vk.DescriptorSetLayout,
  frames:                       [MAX_FRAMES_IN_FLIGHT]struct {
    camera_uniform:        DataBuffer(CameraUniform),
    camera_descriptor_set: vk.DescriptorSet,
  },
}

renderer_shadow_init :: proc(
  self: ^RendererShadow,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  camera_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .UNIFORM_BUFFER_DYNAMIC,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = 1,
      pBindings = raw_data(camera_bindings[:]),
    },
    nil,
    &self.camera_descriptor_set_layout,
  ) or_return
  set_layouts := [?]vk.DescriptorSetLayout {
    self.camera_descriptor_set_layout,
    g_bindless_bone_buffer_set_layout,
  }
  push_constant_range := [?]vk.PushConstantRange {
    {stageFlags = {.VERTEX}, size = size_of(PushConstant)},
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
  vert_module := create_shader_module(SHADER_SHADOW_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states_values),
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
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  pipeline_infos: [SHADOW_SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  configs: [SHADOW_SHADER_VARIANT_COUNT]ShadowShaderConfig
  entries: [SHADOW_SHADER_VARIANT_COUNT][SHADOW_SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  spec_infos: [SHADOW_SHADER_VARIANT_COUNT]vk.SpecializationInfo
  shader_stages: [SHADOW_SHADER_VARIANT_COUNT][1]vk.PipelineShaderStageCreateInfo
  for mask in 0 ..< SHADOW_SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask & ShaderFeatureSet{.SKINNING}
    configs[mask] = {
      is_skinned = .SKINNING in features,
    }
    entries[mask] = [SHADOW_SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
      {
        constantID = 0,
        offset = u32(offset_of(ShadowShaderConfig, is_skinned)),
        size = size_of(b32),
      },
    }
    spec_infos[mask] = {
      mapEntryCount = len(entries[mask]),
      pMapEntries   = raw_data(entries[mask][:]),
      dataSize      = size_of(ShadowShaderConfig),
      pData         = &configs[mask],
    }
    shader_stages[mask] = [1]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
    }
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
  for &frame in self.frames {
    frame.camera_uniform = create_host_visible_buffer(
      CameraUniform,
      (6 * MAX_SHADOW_MAPS),
      {.UNIFORM_BUFFER},
    ) or_return
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
    writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = frame.camera_descriptor_set,
        dstBinding = 0,
        descriptorType = .UNIFORM_BUFFER_DYNAMIC,
        descriptorCount = 1,
        pBufferInfo = &{
          buffer = frame.camera_uniform.buffer,
          range = vk.DeviceSize(size_of(CameraUniform)),
        },
      },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  }
  return .SUCCESS
}

renderer_shadow_deinit :: proc(self: ^RendererShadow) {
  for &frame in self.frames {
    // descriptor set will eventually be freed by the pool
    frame.camera_descriptor_set = 0
  }
  for &p in self.pipelines {
    vk.DestroyPipeline(g_device, p, nil)
    p = 0
  }
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.camera_descriptor_set_layout,
    nil,
  )
  self.camera_descriptor_set_layout = 0
}

renderer_shadow_begin :: proc(
  shadow_target: RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = shadow_target.depth,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}},
  }
  render_info_khr := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = shadow_target.extent},
    layerCount = 1,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info_khr)
  viewport := vk.Viewport {
    width    = f32(shadow_target.extent.width),
    height   = f32(shadow_target.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = {
      width = shadow_target.extent.width,
      height = shadow_target.extent.height,
    },
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

// Render shadow for a single light
renderer_shadow_render :: proc(
  self: ^RendererShadow,
  render_input: RenderInput,
  light_data: LightData,
  shadow_target: RenderTarget,
  shadow_idx: u32, // index of the light in light array
  shadow_layer: u32, // for cube faces (0..5) or 0 for others
  command_buffer: vk.CommandBuffer,
) {
  frame := &self.frames[g_frame_index]
  camera_uniform := data_buffer_get(
    &frame.camera_uniform,
    shadow_idx * 6 + shadow_layer,
  )
  switch light in light_data {
  case PointLightData:
    camera_uniform.projection = light.proj
    camera_uniform.view = light.views[shadow_layer]
  case SpotLightData:
    camera_uniform.projection = light.proj
    camera_uniform.view = light.view
  case DirectionalLightData:
    camera_uniform.projection = light.proj
  }
  current_pipeline: vk.Pipeline = 0
  offset_shadow := data_buffer_offset_of(
    &frame.camera_uniform,
    shadow_idx * 6 + shadow_layer,
  )
  offsets := [1]u32{offset_shadow}
  skinned_descriptor_sets := [?]vk.DescriptorSet {
    frame.camera_descriptor_set,
    g_bindless_bone_buffer_descriptor_set,
  }
  static_descriptor_sets := [?]vk.DescriptorSet{frame.camera_descriptor_set}
  for batch_key, batch_group in render_input.batches {
    // Only care about skinning for shadow pipeline
    shadow_features: ShaderFeatureSet
    is_skinned := .SKINNING in batch_key.features
    if is_skinned {
      shadow_features += {.SKINNING}
    }
    pipeline := renderer_shadow_get_pipeline(self, shadow_features)
    if pipeline != current_pipeline {
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
      current_pipeline = pipeline
    }
    if is_skinned {
      vk.CmdBindDescriptorSets(
        command_buffer,
        .GRAPHICS,
        self.pipeline_layout,
        0,
        len(skinned_descriptor_sets),
        raw_data(skinned_descriptor_sets[:]),
        len(offsets),
        raw_data(offsets[:]),
      )
    } else {
      vk.CmdBindDescriptorSets(
        command_buffer,
        .GRAPHICS,
        self.pipeline_layout,
        0,
        len(static_descriptor_sets),
        raw_data(static_descriptor_sets[:]),
        len(offsets),
        raw_data(offsets[:]),
      )
    }
    for batch_data in batch_group {
      for node in batch_data.nodes {
        render_single_shadow_node(
          command_buffer,
          self.pipeline_layout,
          node,
          is_skinned,
        )
      }
    }
  }
}

renderer_shadow_end :: proc(
  command_buffer: vk.CommandBuffer,
) {
  vk.CmdEndRenderingKHR(command_buffer)
}

renderer_shadow_get_pipeline :: proc(
  self: ^RendererShadow,
  features: ShaderFeatureSet = {},
) -> vk.Pipeline {
  // Extract only the SKINNING bit from features
  mask: u32 = 0
  if .SKINNING in features {
    mask = 1
  }
  return self.pipelines[mask]
}

render_single_shadow_node :: proc(
  command_buffer: vk.CommandBuffer,
  layout: vk.PipelineLayout,
  node: ^Node,
  is_skinned: bool,
) {
  mesh_attachment := node.attachment.(MeshAttachment)
  mesh, found_mesh := resource.get(g_meshes, mesh_attachment.handle)
  if !found_mesh do return
  mesh_skinning, mesh_has_skin := &mesh.skinning.?
  node_skinning, node_has_skin := mesh_attachment.skinning.?
  push_constant := PushConstant {
    world = node.transform.world_matrix,
  }
  if is_skinned && node_has_skin {
    push_constant.bone_matrix_offset = node_skinning.bone_matrix_offset
  }
  vk.CmdPushConstants(
    command_buffer,
    layout,
    {.VERTEX},
    0,
    size_of(PushConstant),
    &push_constant,
  )
  // Always bind both vertex buffer and skinning buffer (real or dummy)
  skin_buffer := g_dummy_skinning_buffer.buffer
  if is_skinned && mesh_has_skin && node_has_skin {
    skin_buffer = mesh_skinning.skin_buffer.buffer
  }
  
  buffers := [2]vk.Buffer{mesh.vertex_buffer.buffer, skin_buffer}
  offsets := [2]vk.DeviceSize{0, 0}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    2,
    raw_data(buffers[:]),
    raw_data(offsets[:]),
  )
  vk.CmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .UINT32)
  vk.CmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0)
}
