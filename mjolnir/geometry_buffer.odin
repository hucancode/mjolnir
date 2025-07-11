package mjolnir

import "core:log"
import "geometry"
import "resource"
import vk "vendor:vulkan"

// 128 byte push constant budget
PushConstant :: struct {
  world:                    matrix[4, 4]f32, // 64 bytes
  bone_matrix_offset:       u32, // 4
  albedo_index:             u32, // 4
  metallic_roughness_index: u32, // 4
  normal_index:             u32, // 4
  emissive_index:           u32, // 4
  metallic_value:           f32, // 4
  roughness_value:          f32, // 4
  emissive_value:           f32, // 4
  camera_index:             u32, // 4
}

RendererGBuffer :: struct {
  pipelines:       [SHADER_VARIANT_COUNT]vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
}

renderer_gbuffer_init :: proc(
  self: ^RendererGBuffer,
  width: u32,
  height: u32,
) -> vk.Result {
  depth_format: vk.Format = .D32_SFLOAT
  set_layouts := [?]vk.DescriptorSetLayout {
    g_bindless_camera_buffer_set_layout, // set = 0 (bindless camera buffer)
    g_textures_set_layout, // set = 1 (bindless textures)
    g_bindless_bone_buffer_set_layout, // set = 2 (bone matrices)
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(PushConstant),
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
  log.info("About to build G-buffer pipelines...")
  vert_shader_code := #load("shader/gbuffer/vert.spv")
  vert_module := create_shader_module(vert_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_shader_code := #load("shader/gbuffer/frag.spv")
  frag_module := create_shader_module(frag_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
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
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = false,
    depthCompareOp   = .LESS_OR_EQUAL,
  }
  color_blend_attachments := [?]vk.PipelineColorBlendAttachmentState {
    {colorWriteMask = {.R, .G, .B, .A}}, // position
    {colorWriteMask = {.R, .G, .B, .A}}, // normal
    {colorWriteMask = {.R, .G, .B, .A}}, // albedo
    {colorWriteMask = {.R, .G, .B, .A}}, // metallic/roughness
    {colorWriteMask = {.R, .G, .B, .A}}, // emissive
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = len(color_blend_attachments),
    pAttachments    = raw_data(color_blend_attachments[:]),
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT, // position
    .R8G8B8A8_UNORM, // normal
    .R8G8B8A8_UNORM, // albedo
    .R8G8B8A8_UNORM, // metallic/roughness
    .R8G8B8A8_UNORM, // emissive
  }
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = depth_format,
  }
  pipeline_infos: [SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  configs: [SHADER_VARIANT_COUNT]ShaderConfig
  entries: [SHADER_VARIANT_COUNT][SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  spec_infos: [SHADER_VARIANT_COUNT]vk.SpecializationInfo
  shader_stages: [SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  for mask in 0 ..< SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask
    configs[mask] = {
      is_skinned                     = .SKINNING in features,
      has_albedo_texture             = .ALBEDO_TEXTURE in features,
      has_metallic_roughness_texture = .METALLIC_ROUGHNESS_TEXTURE in features,
      has_normal_texture             = .NORMAL_TEXTURE in features,
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
    pipeline_infos[mask] = {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      stageCount          = len(shader_stages[mask]),
      pStages             = raw_data(shader_stages[mask][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pDepthStencilState  = &depth_stencil,
      pColorBlendState    = &color_blending,
      pDynamicState       = &dynamic_state,
      layout              = self.pipeline_layout,
      pNext               = &rendering_info,
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
  log.info("G-buffer renderer initialized successfully")
  return .SUCCESS
}

renderer_gbuffer_begin :: proc(
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  position_texture := resource.get(
    g_image_2d_buffers,
    render_target.position_texture,
  )
  position_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = position_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 0.0}}},
  }
  normal_texture := resource.get(
    g_image_2d_buffers,
    render_target.normal_texture,
  )
  normal_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = normal_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  albedo_texture := resource.get(
    g_image_2d_buffers,
    render_target.albedo_texture,
  )
  albedo_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = albedo_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  metallic_roughness_texture := resource.get(
    g_image_2d_buffers,
    render_target.metallic_roughness_texture,
  )
  metallic_roughness_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = metallic_roughness_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  emissive_texture := resource.get(
    g_image_2d_buffers,
    render_target.emissive_texture,
  )
  emissive_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = emissive_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  depth_texture := resource.get(
    g_image_2d_buffers,
    render_target.depth_texture,
  )
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  color_attachments := [?]vk.RenderingAttachmentInfoKHR {
    position_attachment,
    normal_attachment,
    albedo_attachment,
    metallic_roughness_attachment,
    emissive_attachment,
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = render_target.extent},
    layerCount = 1,
    colorAttachmentCount = len(color_attachments),
    pColorAttachments = raw_data(color_attachments[:]),
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(render_target.extent.height),
    width    = f32(render_target.extent.width),
    height   = -f32(render_target.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = render_target.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

renderer_gbuffer_end :: proc(
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  vk.CmdEndRenderingKHR(command_buffer)
}

renderer_gbuffer_render :: proc(
  self: ^RendererGBuffer,
  render_input: ^RenderInput,
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  descriptor_sets := [?]vk.DescriptorSet {
    g_bindless_camera_buffer_descriptor_set,
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
  rendered := 0
  current_pipeline: vk.Pipeline = 0
  for batch_key, batch_group in render_input.batches {
    if batch_key.material_type == .TRANSPARENT ||
       batch_key.material_type == .WIREFRAME {
      continue
    }
    sample_material := resource.get(
      g_materials,
      batch_group[0].material_handle,
    ) or_continue
    pipeline := renderer_gbuffer_get_pipeline(self, sample_material.features)
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
        // DEBUG: Use a constant color for albedo to test G-buffer -> lighting pass
        push_constants := PushConstant {
          world                    = node.transform.world_matrix,
          camera_index             = render_target.camera.index,
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
          emissive_index           = min(
            MAX_TEXTURES - 1,
            material.emissive.index,
          ),
          metallic_value           = material.metallic_value,
          roughness_value          = material.roughness_value,
          emissive_value           = material.emissive_value,
        }
        if skinning, has_skinning := mesh_attachment.skinning.?; has_skinning {
          push_constants.bone_matrix_offset =
            skinning.bone_matrix_offset +
            g_frame_index * g_bone_matrix_slab.capacity
        }
        vk.CmdPushConstants(
          command_buffer,
          self.pipeline_layout,
          {.VERTEX, .FRAGMENT},
          0,
          size_of(PushConstant),
          &push_constants,
        )
        // Always bind both vertex buffer and skinning buffer (real or dummy)
        skin_buffer := g_dummy_skinning_buffer.buffer
        if mesh_skin, mesh_has_skin := mesh.skinning.?; mesh_has_skin {
          skin_buffer = mesh_skin.skin_buffer.buffer
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
}

renderer_gbuffer_get_pipeline :: proc(
  self: ^RendererGBuffer,
  features: ShaderFeatureSet = {},
) -> vk.Pipeline {
  return self.pipelines[transmute(u32)features]
}

renderer_gbuffer_deinit :: proc(self: ^RendererGBuffer) {
  for pipeline in self.pipelines {
    vk.DestroyPipeline(g_device, pipeline, nil)
  }
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
}
