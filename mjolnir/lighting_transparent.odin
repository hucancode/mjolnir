package mjolnir

import "core:fmt"
import "core:log"
import "geometry"
import "resource"
import vk "vendor:vulkan"

RendererTransparent :: struct {
  pipeline_layout:       vk.PipelineLayout,
  transparent_pipelines: [SHADER_VARIANT_COUNT]vk.Pipeline,
  wireframe_pipelines:   [2]vk.Pipeline,
}

transparent_init :: proc(
  self: ^RendererTransparent,
  width: u32,
  height: u32,
) -> vk.Result {
  log.info("Initializing transparent renderer")
  // Use the existing descriptor set layouts
  set_layouts := [?]vk.DescriptorSetLayout {
    g_bindless_camera_buffer_set_layout, // set = 0 (bindless camera buffer)
    g_textures_set_layout, // set = 1 (bindless textures)
    g_bindless_bone_buffer_set_layout, // set = 2 (bone matrices)
  }
  // Create pipeline layout with push constants
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

  create_transparent_pipelines(self) or_return
  create_wireframe_pipelines(self) or_return

  log.info("Transparent renderer initialized successfully")
  return .SUCCESS
}

create_transparent_pipelines :: proc(self: ^RendererTransparent) -> vk.Result {
  // Create all shader variants for transparent PBR materials
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .R8G8B8A8_UNORM
  // Load shader modules at compile time
  vert_shader_code := #load("shader/transparent/vert.spv")
  vert_module := create_shader_module(vert_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_shader_code := #load("shader/transparent/frag.spv")
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
    cullMode    = {.BACK}, // No culling for transparent objects
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }

  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }

  // Enable depth testing but disable depth writing for transparent objects
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true, // Don't write to depth buffer for transparent objects
    depthCompareOp   = .LESS_OR_EQUAL,
  }

  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
    alphaBlendOp        = .ADD,
    colorWriteMask      = {.R, .G, .B, .A},
  }

  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }

  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }

  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_format,
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
    raw_data(self.transparent_pipelines[:]),
  ) or_return

  return .SUCCESS
}

create_wireframe_pipelines :: proc(self: ^RendererTransparent) -> vk.Result {
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .R8G8B8A8_UNORM

  // Load shader modules at compile time
  vert_shader_code := #load("shader/wireframe/vert.spv")
  vert_module := create_shader_module(vert_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)

  frag_shader_code := #load("shader/wireframe/frag.spv")
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

  // Set to LINE polygon mode for wireframe rendering
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .LINE,
    cullMode    = {.BACK}, // No culling for wireframe
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }

  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }

  // Enable depth testing but disable depth writing
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS_OR_EQUAL,
  }

  // Simple alpha blending for wireframe
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask      = {.R, .G, .B, .A},
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp        = .ADD,
  }

  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }

  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }

  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_format,
    depthAttachmentFormat   = depth_format,
  }

  // Create two variants - with and without skinning
  wireframe_configs := [2]ShaderConfig {
    {is_skinned = false}, // Non-skinned variant
    {is_skinned = true}, // Skinned variant
  }

  wireframe_entries := [2]vk.SpecializationMapEntry {
    {constantID = 0, offset = 0, size = size_of(b32)},
    {constantID = 0, offset = 0, size = size_of(b32)},
  }

  wireframe_spec_infos := [2]vk.SpecializationInfo {
    {
      mapEntryCount = 1,
      pMapEntries = &wireframe_entries[0],
      dataSize = size_of(b32),
      pData = &wireframe_configs[0].is_skinned,
    },
    {
      mapEntryCount = 1,
      pMapEntries = &wireframe_entries[1],
      dataSize = size_of(b32),
      pData = &wireframe_configs[1].is_skinned,
    },
  }

  // First create the non-skinned wireframe pipeline
  shader_stages := [2]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
      pSpecializationInfo = &wireframe_spec_infos[0],
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
    },
  }

  create_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
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

  vk.CreateGraphicsPipelines(
    g_device,
    0,
    1,
    &create_info,
    nil,
    &self.wireframe_pipelines[0],
  ) or_return

  // Now create the skinned wireframe pipeline
  // Update the specialization info to use skinned = true
  shader_stages[0].pSpecializationInfo = &wireframe_spec_infos[1]

  vk.CreateGraphicsPipelines(
    g_device,
    0,
    1,
    &create_info,
    nil,
    &self.wireframe_pipelines[1],
  ) or_return

  return .SUCCESS
}

transparent_deinit :: proc(self: ^RendererTransparent) {
  // Destroy all transparent material pipelines
  for i in 0 ..< SHADER_VARIANT_COUNT {
    vk.DestroyPipeline(g_device, self.transparent_pipelines[i], nil)
    self.transparent_pipelines[i] = 0
  }

  // Destroy wireframe material pipelines
  for i in 0 ..< 2 {
    vk.DestroyPipeline(g_device, self.wireframe_pipelines[i], nil)
    self.wireframe_pipelines[i] = 0
  }

  // Destroy pipeline layout
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

transparent_begin :: proc(
  self: ^RendererTransparent,
  render_target: RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  // Setup color attachment - load existing content
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = resource.get(g_image_2d_buffers, render_target.final_image).view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  // Setup depth attachment - load existing depth buffer
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = resource.get(g_image_2d_buffers, render_target.depth_texture).view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  // Begin dynamic rendering
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = render_target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
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

transparent_render :: proc(
  self: ^RendererTransparent,
  render_input: RenderInput,
  render_target: RenderTarget,
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
  // First render transparent materials
  for batch_key, batch_group in render_input.batches {
    if batch_key.material_type == .TRANSPARENT {
      // Get shader variant based on features
      variant_idx := transmute(u32)batch_key.features
      // Bind the pipeline for this variant
      vk.CmdBindPipeline(
        command_buffer,
        .GRAPHICS,
        self.transparent_pipelines[variant_idx],
      )
      for batch_data in batch_group {
        // Process each batch of transparent materials
        material := resource.get(
          g_materials,
          batch_data.material_handle,
        ) or_continue

        // Render all nodes in this batch
        for node in batch_data.nodes {
          mesh_attachment, ok := node.attachment.(MeshAttachment)
          if !ok do continue

          mesh := resource.get(g_meshes, mesh_attachment.handle) or_continue

          push_constants := PushConstant {
            world                    = node.transform.world_matrix,
            bone_matrix_offset       = 0,
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
          // Set bone matrix offset if skinning is available
          if skinning, has_skinning := mesh_attachment.skinning.?;
             has_skinning {
            push_constants.bone_matrix_offset =
              skinning.bone_matrix_offset +
              g_frame_index * g_bone_matrix_slab.capacity
          }

          log.debugf(
            "rendering transparent object with push constant ... %v",
            push_constants,
          )
          // Push constants
          vk.CmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            {.VERTEX, .FRAGMENT},
            0,
            size_of(PushConstant),
            &push_constants,
          )
          // Draw mesh
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
        }
      }
    } else if batch_key.material_type == .WIREFRAME {
      for batch_data in batch_group {
        // Render all nodes in this batch
        for node in batch_data.nodes {
          mesh_attachment, ok := node.attachment.(MeshAttachment)
          if !ok do continue
          mesh := resource.get(g_meshes, mesh_attachment.handle) or_continue
          // Check if skinning feature is enabled
          is_skinned := .SKINNING in batch_key.features
          pipeline_idx := is_skinned ? 1 : 0
          // Bind the appropriate wireframe pipeline
          vk.CmdBindPipeline(
            command_buffer,
            .GRAPHICS,
            self.wireframe_pipelines[pipeline_idx],
          )
          push_constant := PushConstant {
            world        = node.transform.world_matrix,
            camera_index = render_target.camera.index,
          }
          // Set bone matrix offset if skinning is available
          if skinning, has_skinning := mesh_attachment.skinning.?;
             has_skinning {
            push_constant.bone_matrix_offset =
              skinning.bone_matrix_offset +
              g_frame_index * g_bone_matrix_slab.capacity
          }

          // Push constants
          vk.CmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            {.VERTEX, .FRAGMENT},
            0,
            size_of(PushConstant),
            &push_constant,
          )

          // Draw mesh
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
        }
      }
    }
  }
}

transparent_end :: proc(
  self: ^RendererTransparent,
  command_buffer: vk.CommandBuffer,
) {
  vk.CmdEndRenderingKHR(command_buffer)
}
