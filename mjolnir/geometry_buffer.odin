package mjolnir

import "core:log"
import "geometry"
import "gpu"
import "resource"
import vk "vendor:vulkan"

// Simplified push constant for indirect drawing - camera index only
PushConstant :: struct {
  camera_index:        u32, // 4 bytes - index into camera buffer
  padding:             [31]u32, // 124 bytes - rest is unused
}

RendererGBuffer :: struct {
  pipeline:        vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
}

gbuffer_init :: proc(
  self: ^RendererGBuffer,
  gpu_context: ^gpu.GPUContext,
  width, height: u32,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  depth_format: vk.Format = .D32_SFLOAT
  set_layouts := [?]vk.DescriptorSetLayout {
    warehouse.camera_buffer_set_layout,        // set 0
    warehouse.textures_set_layout,            // set 1
    warehouse.bone_buffer_set_layout,         // set 2
    warehouse.material_buffer_set_layout,     // set 3
    warehouse.world_matrix_buffer_set_layout, // set 4
    warehouse.node_data_buffer_set_layout,    // set 5
    warehouse.mesh_data_buffer_set_layout,    // set 6
    warehouse.vertex_skinning_buffer_set_layout, // set 7
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
  log.info("About to build G-buffer pipelines...")
  vert_shader_code := #load("shader/gbuffer/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_shader_code := #load("shader/gbuffer/frag.spv")
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
    depthWriteEnable = true, // Changed to true to enable depth writes in gbuffer pass
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
  // Create single unified pipeline without specialization constants
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
      // No specialization info - features handled at runtime
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
      // No specialization info - features handled at runtime
    },
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
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
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return
  log.info("G-buffer renderer initialized successfully")
  return .SUCCESS
}

gbuffer_begin :: proc(
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
  self_manage_depth: bool = false,
) {
  // Transition all G-buffer textures to COLOR_ATTACHMENT_OPTIMAL
  position_texture := resource.get(
    warehouse.image_2d_buffers,
    get_position_texture(render_target, frame_index),
  )
  normal_texture := resource.get(
    warehouse.image_2d_buffers,
    get_normal_texture(render_target, frame_index),
  )
  albedo_texture := resource.get(
    warehouse.image_2d_buffers,
    get_albedo_texture(render_target, frame_index),
  )
  metallic_roughness_texture := resource.get(
    warehouse.image_2d_buffers,
    get_metallic_roughness_texture(render_target, frame_index),
  )
  emissive_texture := resource.get(
    warehouse.image_2d_buffers,
    get_emissive_texture(render_target, frame_index),
  )
  final_texture := resource.get(
    warehouse.image_2d_buffers,
    get_final_image(render_target, frame_index),
  )

  // Collect all G-buffer images for batch transition
  gbuffer_images := [?]vk.Image {
    position_texture.image,
    normal_texture.image,
    albedo_texture.image,
    metallic_roughness_texture.image,
    emissive_texture.image,
    final_texture.image,
  }

  // Batch transition all G-buffer images to COLOR_ATTACHMENT_OPTIMAL
  gpu.transition_images(
    command_buffer,
    gbuffer_images[:],
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {.COLOR},
    1,
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR_ATTACHMENT_WRITE},
  )

  // Transition depth if self-managing
  if self_manage_depth {
    depth_texture := resource.get(
      warehouse.image_2d_buffers,
      get_depth_texture(render_target, frame_index),
    )
    gpu.transition_image(
      command_buffer,
      depth_texture.image,
      .UNDEFINED,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      {.DEPTH},
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    )
  }
  position_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = position_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 0.0}}},
  }
  normal_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = normal_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  albedo_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = albedo_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  metallic_roughness_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = metallic_roughness_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  emissive_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = emissive_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  depth_texture := resource.get(
    warehouse.image_2d_buffers,
    get_depth_texture(render_target, frame_index),
  )
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = self_manage_depth ? .CLEAR : .LOAD,
    storeOp = .STORE,
    clearValue = {depthStencil = {depth = 1.0, stencil = 0}},
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

gbuffer_end :: proc(
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  vk.CmdEndRenderingKHR(command_buffer)

  // Transition all G-buffer textures to SHADER_READ_ONLY_OPTIMAL for use by lighting
  position_texture := resource.get(
    warehouse.image_2d_buffers,
    get_position_texture(render_target, frame_index),
  )
  normal_texture := resource.get(
    warehouse.image_2d_buffers,
    get_normal_texture(render_target, frame_index),
  )
  albedo_texture := resource.get(
    warehouse.image_2d_buffers,
    get_albedo_texture(render_target, frame_index),
  )
  metallic_roughness_texture := resource.get(
    warehouse.image_2d_buffers,
    get_metallic_roughness_texture(render_target, frame_index),
  )
  emissive_texture := resource.get(
    warehouse.image_2d_buffers,
    get_emissive_texture(render_target, frame_index),
  )

  // Collect G-buffer images for batch transition (excluding final image which stays as attachment)
  gbuffer_images := [?]vk.Image {
    position_texture.image,
    normal_texture.image,
    albedo_texture.image,
    metallic_roughness_texture.image,
    emissive_texture.image,
  }

  // Batch transition all G-buffer images to SHADER_READ_ONLY_OPTIMAL
  gpu.transition_images(
    command_buffer,
    gbuffer_images[:],
    .COLOR_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR},
    1,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.SHADER_READ},
  )
}

// NEW: Indirect drawing version
gbuffer_render :: proc(
  self: ^RendererGBuffer,
  render_input: ^RenderInput,
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  gbuffer_render_indirect(self, render_input, render_target, command_buffer, warehouse, frame_index)
}

// Indirect drawing implementation
gbuffer_render_indirect :: proc(
  self: ^RendererGBuffer,
  render_input: ^RenderInput,
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  // Bind global resources once
  descriptor_sets := [?]vk.DescriptorSet {
    warehouse.camera_buffer_descriptor_set,        // set 0
    warehouse.textures_descriptor_set,            // set 1
    warehouse.bone_buffer_descriptor_set,         // set 2
    warehouse.material_buffer_descriptor_set,     // set 3
    warehouse.world_matrix_buffer_descriptor_set, // set 4
    warehouse.node_data_buffer_descriptor_set,    // set 5
    warehouse.mesh_data_buffer_descriptor_set,    // set 6
    warehouse.vertex_skinning_buffer_descriptor_set, // set 7
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

  // Bind global vertex/index buffers once
  vertex_buffers := [1]vk.Buffer{warehouse.vertex_buffer.buffer}
  vertex_offsets := [1]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(vertex_buffers[:]), raw_data(vertex_offsets[:]))
  vk.CmdBindIndexBuffer(command_buffer, warehouse.index_buffer.buffer, 0, .UINT32)

  // Set camera index in push constants (stays the same for the whole frame)
  push_constants := PushConstant {
    camera_index = render_target.camera.index,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )

  rendered := 0
  current_pipeline: vk.Pipeline = 0
  global_draw_offset: u32 = 0

  for batch_key, batch_group in render_input.batches {
    if batch_key.material_type == .TRANSPARENT ||
       batch_key.material_type == .WIREFRAME {
      continue
    }

    sample_material := resource.get(
      warehouse.materials,
      batch_group[0].material_handle,
    ) or_continue

    pipeline := gbuffer_get_pipeline(self, sample_material.features)
    if pipeline != current_pipeline {
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
      current_pipeline = pipeline
    }

    // Generate draw commands for this pipeline group
    pipeline_draw_count: u32 = 0

    for &batch_data in batch_group {
      // Generate indirect draw commands for this batch
      draw_commands, draw_count := generate_indirect_draw_commands(warehouse, &batch_data)

      // Write draw commands to the buffer at the correct offset
      for cmd, i in draw_commands {
        warehouse.draw_commands_buffer.mapped[global_draw_offset + pipeline_draw_count + u32(i)] = cmd
      }

      pipeline_draw_count += draw_count

      if global_draw_offset + pipeline_draw_count >= warehouse.max_draws_per_batch {
        break // Prevent buffer overflow
      }
    }

    // Execute draws for this pipeline
    if pipeline_draw_count > 0 {
      // Draw all commands for this pipeline
      vk.CmdDrawIndexedIndirect(
        command_buffer,
        warehouse.draw_commands_buffer.buffer,
        vk.DeviceSize(global_draw_offset * size_of(vk.DrawIndexedIndirectCommand)),
        pipeline_draw_count,
        size_of(vk.DrawIndexedIndirectCommand),
      )
      rendered += int(pipeline_draw_count)
      global_draw_offset += pipeline_draw_count
    }
  }

  log.debugf("G-buffer rendered %d meshes using indirect drawing", rendered)
}

// This function has been replaced by generate_indirect_draw_commands in engine.odin
// which uses the new bindless architecture with node handles instead of mesh attachments

// Render large batches in multiple indirect draws
render_in_batches :: proc(
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  total_draws: u32,
) {
  for batch_start := u32(0); batch_start < total_draws; batch_start += warehouse.max_draws_per_batch {
    batch_size := min(warehouse.max_draws_per_batch, total_draws - batch_start)
    offset := vk.DeviceSize(batch_start * size_of(vk.DrawIndexedIndirectCommand))

    vk.CmdDrawIndexedIndirect(
      command_buffer,
      warehouse.draw_commands_buffer.buffer,
      offset,
      batch_size,
      size_of(vk.DrawIndexedIndirectCommand),
    )
  }
}

gbuffer_get_pipeline :: proc(
  self: ^RendererGBuffer,
  features: ShaderFeatureSet = {},
) -> vk.Pipeline {
  // Features are now handled at runtime in shaders, just return the single pipeline
  return self.pipeline
}

gbuffer_deinit :: proc(self: ^RendererGBuffer, gpu_context: ^gpu.GPUContext) {
  vk.DestroyPipeline(gpu_context.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gpu_context.device, self.pipeline_layout, nil)
}
