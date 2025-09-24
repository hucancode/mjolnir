package mjolnir

import "core:log"
import "geometry"
import "gpu"
import "resource"
import vk "vendor:vulkan"

SHADER_SHADOW_VERT :: #load("shader/shadow/vert.spv")
SHADER_SHADOW_FRAG :: #load("shader/shadow/frag.spv")

RendererShadow :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipelines:       [SHADOW_SHADER_VARIANT_COUNT]vk.Pipeline,
}

shadow_init :: proc(
  self: ^RendererShadow,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  set_layouts := [?]vk.DescriptorSetLayout {
    warehouse.camera_buffer_set_layout,
    warehouse.textures_set_layout,
    warehouse.bone_buffer_set_layout,
    warehouse.material_buffer_set_layout,
    warehouse.world_matrix_buffer_set_layout,
    warehouse.mesh_data_buffer_set_layout,
    warehouse.vertex_skinning_buffer_set_layout,
  }
  push_constant_range := [?]vk.PushConstantRange {
    {stageFlags = {.FRAGMENT, .VERTEX}, size = size_of(PushConstant)},
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
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
  vert_module := gpu.create_shader_module(
    gpu_context,
    SHADER_SHADOW_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gpu_context,
    SHADER_SHADOW_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_module, nil)
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
    frontFace               = .CLOCKWISE,
    lineWidth               = 1.0,
    depthBiasEnable         = true,
    depthBiasConstantFactor = 1.0,
    depthBiasClamp          = 0.01,
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
  pipeline_info := vk.GraphicsPipelineCreateInfo {
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
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipelines[0],
  ) or_return
  return .SUCCESS
}

shadow_deinit :: proc(self: ^RendererShadow, gpu_context: ^gpu.GPUContext) {
  for &p in self.pipelines {
    vk.DestroyPipeline(gpu_context.device, p, nil)
    p = 0
  }
  vk.DestroyPipelineLayout(gpu_context.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

shadow_begin :: proc(
  shadow_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
  face: Maybe(u32) = nil,
) {
  depth_image_view: vk.ImageView
  depth_image: vk.Image
  face_index, has_face := face.?
  if has_face {
    cube_texture := resource.get(
      warehouse.image_cube_buffers,
      get_depth_texture(shadow_target, frame_index),
    )
    if cube_texture == nil {
      log.errorf(
        "Invalid cube shadow map handle: %v",
        get_depth_texture(shadow_target, frame_index),
      )
      return
    }
    depth_image_view = cube_texture.face_views[face_index]
    depth_image = cube_texture.image
  } else {
    texture_2d := resource.get(
      warehouse.image_2d_buffers,
      get_depth_texture(shadow_target, frame_index),
    )
    if texture_2d == nil {
      log.errorf(
        "Invalid 2D shadow map handle: %v",
        get_depth_texture(shadow_target, frame_index),
      )
      return
    }
    depth_image_view = texture_2d.view
    depth_image = texture_2d.image
  }

  // Transition shadow map to depth attachment optimal in this command buffer
  // This eliminates the race condition with main command buffer transitions
  layer_count: u32 = 1 if !has_face else 6
  gpu.transition_image(
    command_buffer,
    depth_image,
    .UNDEFINED,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    {.DEPTH},
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    layer_count,
  )

  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = depth_image_view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}}, // Clear to far distance
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
shadow_render :: proc(
  self: ^RendererShadow,
  render_input: RenderInput,
  light_info: LightInfo,
  shadow_target: RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  current_pipeline: vk.Pipeline = 0
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
  rendered_count := 0
  for _, batch_group in render_input.batches {
    pipeline := shadow_get_pipeline(self)
    if pipeline != current_pipeline {
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
      current_pipeline = pipeline
    }
    for batch_data in batch_group {
      for render_node in batch_data.nodes {
        render_single_shadow_node(
          command_buffer,
          self.pipeline_layout,
          render_node.node,
          render_node.handle,
          shadow_target.camera.index,
          warehouse,
          frame_index,
        )
        rendered_count += 1
      }
    }
  }
}

shadow_end :: proc(
  command_buffer: vk.CommandBuffer,
  shadow_target: ^RenderTarget,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
  face: Maybe(u32) = nil,
) {
  vk.CmdEndRenderingKHR(command_buffer)

  // Transition shadow map to shader read optimal after rendering
  depth_image: vk.Image
  face_index, has_face := face.?
  if has_face {
    cube_texture := resource.get(
      warehouse.image_cube_buffers,
      get_depth_texture(shadow_target, frame_index),
    )
    if cube_texture == nil {
      log.errorf(
        "Invalid cube shadow map handle: %v",
        get_depth_texture(shadow_target, frame_index),
      )
      return
    }
    depth_image = cube_texture.image
  } else {
    texture_2d := resource.get(
      warehouse.image_2d_buffers,
      get_depth_texture(shadow_target, frame_index),
    )
    if texture_2d == nil {
      log.errorf(
        "Invalid 2D shadow map handle: %v",
        get_depth_texture(shadow_target, frame_index),
      )
      return
    }
    depth_image = texture_2d.image
  }

  layer_count: u32 = 1 if !has_face else 6
  gpu.transition_image(
    command_buffer,
    depth_image,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.DEPTH},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    layer_count,
  )
}

shadow_get_pipeline :: proc(
  self: ^RendererShadow,
  _: ShaderFeatureSet = {},
) -> vk.Pipeline {
  return self.pipelines[0]
}

render_single_shadow_node :: proc(
  command_buffer: vk.CommandBuffer,
  layout: vk.PipelineLayout,
  node: ^Node,
  node_handle: Handle,
  camera_index: u32,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  mesh_attachment := node.attachment.(MeshAttachment)
  mesh, found_mesh := mesh(warehouse, mesh_attachment.handle)
  if !found_mesh do return
  node_skinning, node_has_skin := mesh_attachment.skinning.?
  push_constant := PushConstant {
    node_id      = node_handle.index,
    camera_index = camera_index,
    material_id  = mesh_attachment.material.index,
    mesh_id      = mesh_attachment.handle.index,
  }
  if node_has_skin {
    push_constant.bone_matrix_offset =
      node_skinning.bone_matrix_offset +
      frame_index * warehouse.bone_matrix_slab.capacity
  }
  vk.CmdPushConstants(
    command_buffer,
    layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constant,
  )
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
  vk.CmdDrawIndexed(command_buffer, mesh.index_allocation.count, 1, 0, 0, 0)
}
