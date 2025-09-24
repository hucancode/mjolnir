package mjolnir

import "core:log"
import "geometry"
import "gpu"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

SHADER_DEPTH_PREPASS_VERT :: #load("shader/depth_prepass/vert.spv")

DEPTH_PREPASS_OPTION_COUNT :: 0
DEPTH_PREPASS_VARIANT_COUNT: u32 : 1 << DEPTH_PREPASS_OPTION_COUNT

RendererDepthPrepass :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
}

depth_prepass_init :: proc(
  self: ^RendererDepthPrepass,
  gpu_context: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  warehouse: ^ResourceWarehouse,
) -> (
  res: vk.Result,
) {
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    size       = size_of(PushConstant),
  }
  set_layouts := [?]vk.DescriptorSetLayout {
    warehouse.camera_buffer_set_layout,
    warehouse.textures_set_layout,
    warehouse.bone_buffer_set_layout,
    warehouse.material_buffer_set_layout,
    warehouse.world_matrix_buffer_set_layout,
    warehouse.node_data_buffer_set_layout,
    warehouse.mesh_data_buffer_set_layout,
    warehouse.vertex_skinning_buffer_set_layout,
  }
  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = len(set_layouts),
    pSetLayouts            = raw_data(set_layouts[:]),
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &pipeline_layout_info,
    nil,
    &self.pipeline_layout,
  ) or_return
  depth_prepass_build_pipeline(
    gpu_context,
    self,
    &self.pipeline,
    swapchain_extent,
  ) or_return
  return .SUCCESS
}

depth_prepass_deinit :: proc(
  self: ^RendererDepthPrepass,
  gpu_context: ^gpu.GPUContext,
) {
  if self.pipeline != 0 {
    vk.DestroyPipeline(gpu_context.device, self.pipeline, nil)
    self.pipeline = 0
  }
  vk.DestroyPipelineLayout(gpu_context.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

depth_prepass_begin :: proc(
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  depth_texture := resource.get(
    warehouse.image_2d_buffers,
    get_depth_texture(render_target, frame_index),
  )
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = render_target.extent},
    layerCount = 1,
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
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  scissor := vk.Rect2D {
    offset = {x = 0, y = 0},
    extent = render_target.extent,
  }
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

depth_prepass_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

depth_prepass_render :: proc(
  self: ^RendererDepthPrepass,
  render_input: ^RenderInput,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) -> int {
  rendered_count := 0
  descriptor_sets := [?]vk.DescriptorSet {
    warehouse.camera_buffer_descriptor_set,
    warehouse.textures_descriptor_set,
    warehouse.bone_buffer_descriptor_set,
    warehouse.material_buffer_descriptor_set,
    warehouse.world_matrix_descriptor_sets[frame_index],
    warehouse.node_data_descriptor_set,
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
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipeline)
  for batch_key, batch_group in render_input.batches {
    if batch_key.material_type == .WIREFRAME ||
       batch_key.material_type == .TRANSPARENT {
      continue
    }
    for batch_data in batch_group {
      _, material_found := resource.get(
        warehouse.materials,
        batch_data.material_handle,
      )
      if !material_found do continue
      for render_node in batch_data.nodes {
        node := render_node.node
        #partial switch data in node.attachment {
        case MeshAttachment:
          mesh := mesh(warehouse, data.handle) or_continue
          push_constant := PushConstant {
            camera_index = camera_index,
          }
          vk.CmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            {.VERTEX},
            0,
            size_of(PushConstant),
            &push_constant,
          )
          vertex_offset := vk.DeviceSize(mesh.vertex_allocation.offset * size_of(geometry.Vertex))
          buffers := [1]vk.Buffer{warehouse.vertex_buffer.buffer}
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
            render_node.handle.index,
          )
          rendered_count += 1
        }
      }
    }
  }
  return rendered_count
}

depth_prepass_build_pipeline :: proc(
  gpu_context: ^gpu.GPUContext,
  self: ^RendererDepthPrepass,
  pipeline: ^vk.Pipeline,
  swapchain_extent: vk.Extent2D,
) -> (
  res: vk.Result,
) {
  log.debug("Building depth prepass pipeline")
  vert_shader_module := gpu.create_shader_module(
    gpu_context,
    SHADER_DEPTH_PREPASS_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_shader_module, nil)
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
    },
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
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
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
    depthBiasConstantFactor = 0.1,
    depthBiasSlopeFactor    = 0.2,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    sampleShadingEnable  = false,
    rasterizationSamples = {._1},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }
  dynamic_rendering := vk.PipelineRenderingCreateInfoKHR {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &dynamic_rendering,
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
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    pipeline,
  ) or_return
  return .SUCCESS
}
