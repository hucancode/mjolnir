package mjolnir

import "core:log"
import "geometry"
import "gpu"
import "resource"
import vk "vendor:vulkan"

RendererTransparent :: struct {
  pipeline_layout:       vk.PipelineLayout,
  transparent_pipelines: [SHADER_VARIANT_COUNT]vk.Pipeline,
  wireframe_pipelines:   [1]vk.Pipeline,
}

transparent_init :: proc(
  self: ^RendererTransparent,
  gpu_context: ^gpu.GPUContext,
  width, height: u32,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.info("Initializing transparent renderer")
  set_layouts := [?]vk.DescriptorSetLayout {
    warehouse.camera_buffer_set_layout,
    warehouse.textures_set_layout,
    warehouse.bone_buffer_set_layout,
    warehouse.material_buffer_set_layout,
    warehouse.world_matrix_buffer_set_layout,
    warehouse.mesh_data_buffer_set_layout,
    warehouse.vertex_skinning_buffer_set_layout,
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(PushConstant),
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
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

  create_transparent_pipelines(gpu_context, self) or_return
  create_wireframe_pipelines(gpu_context, self) or_return

  log.info("Transparent renderer initialized successfully")
  return .SUCCESS
}

create_transparent_pipelines :: proc(
  gpu_context: ^gpu.GPUContext,
  self: ^RendererTransparent,
) -> vk.Result {
  // Create all shader variants for transparent PBR materials
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
  // Load shader modules at compile time
  vert_shader_code := #load("shader/transparent/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_shader_code := #load("shader/transparent/frag.spv")
  frag_module := gpu.create_shader_module(
    gpu_context,
    frag_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_module, nil)

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
      has_albedo_texture             = .ALBEDO_TEXTURE in features,
      has_metallic_roughness_texture = .METALLIC_ROUGHNESS_TEXTURE in features,
      has_normal_texture             = .NORMAL_TEXTURE in features,
      has_emissive_texture           = .EMISSIVE_TEXTURE in features,
      has_occlusion_texture          = .OCCLUSION_TEXTURE in features,
    }
    entries[mask] = [SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
      {
        constantID = 0,
        offset = u32(offset_of(ShaderConfig, has_albedo_texture)),
        size = size_of(b32),
      },
      {
        constantID = 1,
        offset = u32(offset_of(ShaderConfig, has_metallic_roughness_texture)),
        size = size_of(b32),
      },
      {
        constantID = 2,
        offset = u32(offset_of(ShaderConfig, has_normal_texture)),
        size = size_of(b32),
      },
      {
        constantID = 3,
        offset = u32(offset_of(ShaderConfig, has_emissive_texture)),
        size = size_of(b32),
      },
      {
        constantID = 4,
        offset = u32(offset_of(ShaderConfig, has_occlusion_texture)),
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
    gpu_context.device,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.transparent_pipelines[:]),
  ) or_return

  return .SUCCESS
}

create_wireframe_pipelines :: proc(
  gpu_context: ^gpu.GPUContext,
  self: ^RendererTransparent,
) -> vk.Result {
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB

  // Load shader modules at compile time
  vert_shader_code := #load("shader/wireframe/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)

  frag_shader_code := #load("shader/wireframe/frag.spv")
  frag_module := gpu.create_shader_module(
    gpu_context,
    frag_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_module, nil)

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
  shader_stages := [2]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
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
    gpu_context.device,
    0,
    1,
    &create_info,
    nil,
    &self.wireframe_pipelines[0],
  ) or_return

  return .SUCCESS
}

transparent_deinit :: proc(
  self: ^RendererTransparent,
  gpu_context: ^gpu.GPUContext,
) {
  // Destroy all transparent material pipelines
  for i in 0 ..< SHADER_VARIANT_COUNT {
    vk.DestroyPipeline(gpu_context.device, self.transparent_pipelines[i], nil)
    self.transparent_pipelines[i] = 0
  }

  // Destroy wireframe material pipelines
  for i in 0 ..< len(self.wireframe_pipelines) {
    vk.DestroyPipeline(gpu_context.device, self.wireframe_pipelines[i], nil)
    self.wireframe_pipelines[i] = 0
  }

  // Destroy pipeline layout
  vk.DestroyPipelineLayout(gpu_context.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

transparent_begin :: proc(
  self: ^RendererTransparent,
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  // Setup color attachment - load existing content
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = image_2d(warehouse, get_final_image(render_target, frame_index)).view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  // Setup depth attachment - load existing depth buffer
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = image_2d(warehouse, get_depth_texture(render_target, frame_index)).view,
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
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  descriptor_sets := [?]vk.DescriptorSet {
    warehouse.camera_buffer_descriptor_set,
    warehouse.textures_descriptor_set,
    warehouse.bone_buffer_descriptor_set,
    warehouse.material_buffer_descriptor_set,
    warehouse.world_matrix_descriptor_sets[frame_index],
    warehouse.mesh_data_descriptor_set,
    warehouse.vertex_skinning_descriptor_set,
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
        _, material_found := resource.get(
          warehouse.materials,
          batch_data.material_handle,
        )
        if !material_found do continue

        // Render all nodes in this batch
        for render_node in batch_data.nodes {
          node := render_node.node
          mesh_attachment, ok := node.attachment.(MeshAttachment)
          if !ok do continue

          mesh := resource.get(
            warehouse.meshes,
            mesh_attachment.handle,
          ) or_continue

          push_constants := PushConstant {
            node_id            = render_node.handle.index,
            bone_matrix_offset = 0,
            camera_index       = render_target.camera.index,
            material_id        = batch_data.material_handle.index,
            mesh_id            = mesh_attachment.handle.index,
          }
          if skinning, has_skinning := mesh_attachment.skinning.?;
             has_skinning {
            push_constants.bone_matrix_offset =
              skinning.bone_matrix_offset +
              frame_index * warehouse.bone_matrix_slab.capacity
          }
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
          buffers := [1]vk.Buffer{warehouse.vertex_buffer.buffer}
          vertex_offset := vk.DeviceSize(
            mesh.vertex_allocation.offset * size_of(geometry.Vertex),
          )
          offsets := [1]vk.DeviceSize{vertex_offset}
          vk.CmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            raw_data(buffers[:]),
            raw_data(offsets[:]),
          )
          vk.CmdBindIndexBuffer(
            command_buffer,
            warehouse.index_buffer.buffer,
            vk.DeviceSize(mesh.index_allocation.offset * size_of(u32)),
            .UINT32,
          )
          vk.CmdDrawIndexed(
            command_buffer,
            mesh.index_allocation.count,
            1,
            0,
            0,
            0,
          )
        }
      }
    } else if batch_key.material_type == .WIREFRAME {
      for batch_data in batch_group {
        // Render all nodes in this batch
        for render_node in batch_data.nodes {
          node := render_node.node
          mesh_attachment, ok := node.attachment.(MeshAttachment)
          if !ok do continue
          mesh := resource.get(
            warehouse.meshes,
            mesh_attachment.handle,
          ) or_continue
          // Bind the wireframe pipeline
          vk.CmdBindPipeline(
            command_buffer,
            .GRAPHICS,
            self.wireframe_pipelines[0],
          )
          push_constant := PushConstant {
            node_id      = render_node.handle.index,
            camera_index = render_target.camera.index,
            material_id  = batch_data.material_handle.index,
            mesh_id      = mesh_attachment.handle.index,
          }
          // Set bone matrix offset if skinning is available
          if skinning, has_skinning := mesh_attachment.skinning.?;
             has_skinning {
            push_constant.bone_matrix_offset =
              skinning.bone_matrix_offset +
              frame_index * warehouse.bone_matrix_slab.capacity
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
          buffers := [1]vk.Buffer{warehouse.vertex_buffer.buffer}
          vertex_offset := vk.DeviceSize(
            mesh.vertex_allocation.offset * size_of(geometry.Vertex),
          )
          offsets := [1]vk.DeviceSize{vertex_offset}
          vk.CmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            raw_data(buffers[:]),
            raw_data(offsets[:]),
          )
          vk.CmdBindIndexBuffer(
            command_buffer,
            warehouse.index_buffer.buffer,
            vk.DeviceSize(mesh.index_allocation.offset * size_of(u32)),
            .UINT32,
          )
          vk.CmdDrawIndexed(
            command_buffer,
            mesh.index_allocation.count,
            1,
            0,
            0,
            0,
          )
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
