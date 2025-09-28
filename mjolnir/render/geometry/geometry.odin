package geometry_pass

import "core:log"
import geometry "../../geometry"
import gpu "../../gpu"
import resources "../../resources"
import vk "vendor:vulkan"

// 64 byte push constant budget
PushConstant :: struct {
  camera_index: u32,
}

Renderer :: struct {
  pipeline:        vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  depth_prepass_pipeline:        vk.Pipeline,
  commands:        [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

SHADER_DEPTH_PREPASS_VERT :: #load("../../shader/depth_prepass/vert.spv")


begin_depth_prepass :: proc(
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_depth_texture(render_target, frame_index),
  )
  depth_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfo{
    sType = .RENDERING_INFO,
    renderArea = {extent = render_target.extent},
    layerCount = 1,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
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

end_depth_prepass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

render_depth_prepass :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  resources_manager: ^resources.Manager,
  frame_index: u32,
  draw_buffer: vk.Buffer,
  draw_count: u32,
  command_stride: u32,
) -> int {
  if draw_count == 0 {
    return 0
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
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.depth_prepass_pipeline)
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
  vk.CmdDrawIndexedIndirect(
    command_buffer,
    draw_buffer,
    0,
    draw_count,
    command_stride,
  )
  return int(draw_count)
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

  // Initialize depth prepass pipeline first
  log.debug("Building depth prepass pipeline")
  depth_vert_shader_module := gpu.create_shader_module(
    gpu_context.device,
    SHADER_DEPTH_PREPASS_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, depth_vert_shader_module, nil)
  depth_shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = depth_vert_shader_module,
      pName = "main",
    },
  }
  depth_vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
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
  depth_dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  depth_dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(depth_dynamic_states),
    pDynamicStates    = raw_data(depth_dynamic_states[:]),
  }
  depth_input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }
  depth_viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  depth_rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    lineWidth               = 1.0,
    depthBiasEnable         = true,
    depthBiasConstantFactor = 0.1,
    depthBiasSlopeFactor    = 0.2,
  }
  depth_multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    sampleShadingEnable  = false,
    rasterizationSamples = {._1},
  }
  depth_color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
  }
  depth_depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }
  depth_dynamic_rendering := vk.PipelineRenderingCreateInfo{
    sType                 = .PIPELINE_RENDERING_CREATE_INFO,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  depth_pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &depth_dynamic_rendering,
    stageCount          = len(depth_shader_stages),
    pStages             = raw_data(depth_shader_stages[:]),
    pVertexInputState   = &depth_vertex_input_info,
    pInputAssemblyState = &depth_input_assembly,
    pViewportState      = &depth_viewport_state,
    pRasterizationState = &depth_rasterizer,
    pMultisampleState   = &depth_multisampling,
    pDepthStencilState  = &depth_depth_stencil,
    pColorBlendState    = &depth_color_blending,
    pDynamicState       = &depth_dynamic_state,
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &depth_pipeline_info,
    nil,
    &self.depth_prepass_pipeline,
  ) or_return

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
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
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
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
  self_manage_depth: bool = false,
) {
  // Transition all G-buffer textures to COLOR_ATTACHMENT_OPTIMAL
  position_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_position_texture(render_target, frame_index),
  )
  normal_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_normal_texture(render_target, frame_index),
  )
  albedo_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_albedo_texture(render_target, frame_index),
  )
  metallic_roughness_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_metallic_roughness_texture(render_target, frame_index),
  )
  emissive_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_emissive_texture(render_target, frame_index),
  )
  final_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_final_image(render_target, frame_index),
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
    depth_texture := resources.get(
      resources_manager.image_2d_buffers,
      resources.get_depth_texture(render_target, frame_index),
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
  position_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = position_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 0.0}}},
  }
  normal_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = normal_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  albedo_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = albedo_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  metallic_roughness_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = metallic_roughness_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  emissive_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = emissive_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_depth_texture(render_target, frame_index),
  )
  depth_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
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
  vk.CmdBeginRendering(command_buffer, &render_info)
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

end_pass :: proc(
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  vk.CmdEndRendering(command_buffer)

  // Transition all G-buffer textures to SHADER_READ_ONLY_OPTIMAL for use by lighting
  position_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_position_texture(render_target, frame_index),
  )
  normal_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_normal_texture(render_target, frame_index),
  )
  albedo_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_albedo_texture(render_target, frame_index),
  )
  metallic_roughness_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_metallic_roughness_texture(render_target, frame_index),
  )
  emissive_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_emissive_texture(render_target, frame_index),
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

render :: proc(
  self: ^Renderer,
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
  draw_buffer: vk.Buffer,
  draw_count: u32,
  command_stride: u32,
) {
  if draw_count == 0 {
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
  vk.CmdDrawIndexedIndirect(
    command_buffer,
    draw_buffer,
    0,
    draw_count,
    command_stride,
  )
}

shutdown :: proc(self: ^Renderer, device: vk.Device, command_pool: vk.CommandPool) {
  gpu.free_command_buffers(device, command_pool, self.commands[:])
  vk.DestroyPipeline(device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipeline(device, self.depth_prepass_pipeline, nil)
  self.depth_prepass_pipeline = 0
}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  main_render_target: ^resources.RenderTarget,
  resources_manager: ^resources.Manager,
) -> (command_buffer: vk.CommandBuffer, ret: vk.Result) {
  command_buffer = self.commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return

  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
  }
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  // Transition depth texture to depth attachment optimal
  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_depth_texture(main_render_target, frame_index),
  )
  if depth_texture != nil {
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

  return command_buffer, .SUCCESS
}

end_record :: proc(
  command_buffer: vk.CommandBuffer,
  main_render_target: ^resources.RenderTarget,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) -> vk.Result {
  // Transition depth texture to shader read optimal for use by lighting
  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_depth_texture(main_render_target, frame_index),
  )
  if depth_texture != nil {
    gpu.transition_image(
      command_buffer,
      depth_texture.image,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      .SHADER_READ_ONLY_OPTIMAL,
      {.DEPTH},
      {.LATE_FRAGMENT_TESTS},
      {.FRAGMENT_SHADER},
      {.SHADER_READ},
    )
  }

  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}
