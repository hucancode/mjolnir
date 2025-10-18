package geometry_pass

import "../../geometry"
import "../../gpu"
import "../../resources"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

// 64 byte push constant budget
PushConstant :: struct {
  camera_index: u32,
}

Renderer :: struct {
  pipeline:        vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  commands:        [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

init :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  width, height: u32,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  gpu.allocate_secondary_buffers(
    gpu_context.device,
    gpu_context.command_pool,
    self.commands[:],
  ) or_return

  depth_format: vk.Format = .D32_SFLOAT
  self.pipeline_layout = resources_manager.geometry_pipeline_layout
  if self.pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  spec_data, spec_entries, spec_info := shared.make_shader_spec_constants()
  spec_info.pData = cast(rawptr)&spec_data
  defer delete(spec_entries)

  // Initialize G-buffer pipeline
  log.info("About to build G-buffer pipelines...")
  vert_shader_code := #load("../../shader/gbuffer/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context.device,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_shader_code := #load("../../shader/gbuffer/frag.spv")
  frag_module := gpu.create_shader_module(
    gpu_context.device,
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
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
      pSpecializationInfo = &spec_info,
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
      pSpecializationInfo = &spec_info,
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

begin_pass :: proc(
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  camera := resources.get(resources_manager.cameras, camera_handle)
  if camera == nil do return
  // Transition all G-buffer textures to COLOR_ATTACHMENT_OPTIMAL
  position_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .POSITION, frame_index),
  )
  normal_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .NORMAL, frame_index),
  )
  albedo_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .ALBEDO, frame_index),
  )
  metallic_roughness_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .METALLIC_ROUGHNESS, frame_index),
  )
  emissive_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .EMISSIVE, frame_index),
  )
  final_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .FINAL_IMAGE, frame_index),
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

  // Note: Depth texture is already in DEPTH_STENCIL_READ_ONLY_OPTIMAL from visibility system
  // No transition needed - just get the texture for attachment setup
  // Use per-frame depth attachment from camera.attachments[.DEPTH][frame_index]
  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    camera.attachments[.DEPTH][frame_index],
  )

  position_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = position_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 0.0}}},
  }
  normal_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = normal_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  albedo_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = albedo_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  metallic_roughness_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = metallic_roughness_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  emissive_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = emissive_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  depth_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    loadOp = .LOAD,
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
  extent := camera.extent
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = extent},
    layerCount = 1,
    colorAttachmentCount = len(color_attachments),
    pColorAttachments = raw_data(color_attachments[:]),
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0,
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
}

end_pass :: proc(
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  vk.CmdEndRendering(command_buffer)

  camera := resources.get(resources_manager.cameras, camera_handle)
  if camera == nil do return

  // Transition all G-buffer textures to SHADER_READ_ONLY_OPTIMAL for use by lighting
  position_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .POSITION, frame_index),
  )
  normal_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .NORMAL, frame_index),
  )
  albedo_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .ALBEDO, frame_index),
  )
  metallic_roughness_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .METALLIC_ROUGHNESS, frame_index),
  )
  emissive_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.camera_get_attachment(camera, .EMISSIVE, frame_index),
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

// Render using the late culled draw list for this frame
render :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
  command_stride: u32,
) {
  if draw_buffer == 0 || count_buffer == 0 {
    return
  }
  descriptor_sets := [?]vk.DescriptorSet {
    resources_manager.camera_buffer_descriptor_set,
    resources_manager.textures_descriptor_set,
    resources_manager.bone_buffer_descriptor_set,
    resources_manager.material_buffer_descriptor_set,
    resources_manager.world_matrix_descriptor_set,
    resources_manager.node_data_descriptor_set,
    resources_manager.mesh_data_descriptor_set,
    resources_manager.vertex_skinning_descriptor_set,
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
  push_constants := PushConstant {
    camera_index = camera_handle.index,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  vertex_buffers := [1]vk.Buffer{resources_manager.vertex_buffer.buffer}
  vertex_offsets := [1]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    raw_data(vertex_buffers[:]),
    raw_data(vertex_offsets[:]),
  )
  vk.CmdBindIndexBuffer(
    command_buffer,
    resources_manager.index_buffer.buffer,
    0,
    .UINT32,
  )
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_buffer,
    0,
    count_buffer,
    0,
    resources.MAX_NODES_IN_SCENE,
    command_stride,
  )
}

shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
) {
  gpu.free_command_buffers(device, command_pool, self.commands[:])
  vk.DestroyPipeline(device, self.pipeline, nil)
  self.pipeline = 0
}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  camera_handle: resources.Handle,
  resources_manager: ^resources.Manager,
) -> (
  command_buffer: vk.CommandBuffer,
  ret: vk.Result,
) {
  command_buffer = self.commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return

  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
  }
  rendering_info := vk.CommandBufferInheritanceRenderingInfo {
    sType                   = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo {
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return
  return command_buffer, .SUCCESS
}

end_record :: proc(
  command_buffer: vk.CommandBuffer,
  camera_handle: resources.Handle,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) -> vk.Result {
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}
