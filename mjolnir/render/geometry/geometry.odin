package geometry_pass

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../../resources"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_G_BUFFER_VERT :: #load("../../shader/gbuffer/vert.spv")
SHADER_G_BUFFER_FRAG :: #load("../../shader/gbuffer/frag.spv")

PushConstant :: struct {
  camera_index: u32,
}

Renderer :: struct {
  pipeline: vk.Pipeline,
  commands: [resources.FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  width, height: u32,
  rm: ^resources.Manager,
) -> (
  ret: vk.Result,
) {
  gpu.allocate_command_buffer(gctx, self.commands[:], .SECONDARY) or_return
  defer if ret != .SUCCESS {
    gpu.free_command_buffer(gctx, ..self.commands[:])
  }
  depth_format: vk.Format = .D32_SFLOAT
  if rm.geometry_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  log.info("About to build G-buffer pipelines...")
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_G_BUFFER_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_G_BUFFER_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
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
  color_blend_attachments := [?]vk.PipelineColorBlendAttachmentState {
    gpu.BLEND_OVERRIDE, // position
    gpu.BLEND_OVERRIDE, // normal
    gpu.BLEND_OVERRIDE, // albedo
    gpu.BLEND_OVERRIDE, // metallic/roughness
    gpu.BLEND_OVERRIDE, // emissive
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = len(color_blend_attachments),
    pAttachments    = raw_data(color_blend_attachments[:]),
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
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &color_blending,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = rm.geometry_pipeline_layout,
    pNext               = &rendering_info,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
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
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  // Transition all G-buffer textures to COLOR_ATTACHMENT_OPTIMAL
  position_texture := cont.get(
    rm.images_2d,
    camera.attachments[.POSITION][frame_index],
  )
  normal_texture := cont.get(
    rm.images_2d,
    camera.attachments[.NORMAL][frame_index],
  )
  albedo_texture := cont.get(
    rm.images_2d,
    camera.attachments[.ALBEDO][frame_index],
  )
  metallic_roughness_texture := cont.get(
    rm.images_2d,
    camera.attachments[.METALLIC_ROUGHNESS][frame_index],
  )
  emissive_texture := cont.get(
    rm.images_2d,
    camera.attachments[.EMISSIVE][frame_index],
  )
  final_texture := cont.get(
    rm.images_2d,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  // Transition all G-buffer images from UNDEFINED to COLOR_ATTACHMENT_OPTIMAL
  gpu.image_barrier(
    command_buffer,
    position_texture.image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    normal_texture.image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    albedo_texture.image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    metallic_roughness_texture.image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    emissive_texture.image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    final_texture.image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    camera.extent.width,
    camera.extent.height,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(position_texture),
    gpu.create_color_attachment(normal_texture),
    gpu.create_color_attachment(albedo_texture),
    gpu.create_color_attachment(metallic_roughness_texture),
    gpu.create_color_attachment(emissive_texture),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    camera.extent.width,
    camera.extent.height,
  )
}

end_pass :: proc(
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  vk.CmdEndRendering(command_buffer)
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  // transition all G-buffer textures to SHADER_READ_ONLY_OPTIMAL for use by lighting and post-processing
  position_texture := cont.get(
    rm.images_2d,
    camera.attachments[.POSITION][frame_index],
  )
  normal_texture := cont.get(
    rm.images_2d,
    camera.attachments[.NORMAL][frame_index],
  )
  albedo_texture := cont.get(
    rm.images_2d,
    camera.attachments[.ALBEDO][frame_index],
  )
  metallic_roughness_texture := cont.get(
    rm.images_2d,
    camera.attachments[.METALLIC_ROUGHNESS][frame_index],
  )
  emissive_texture := cont.get(
    rm.images_2d,
    camera.attachments[.EMISSIVE][frame_index],
  )
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  // transition all G-buffer attachments + depth to SHADER_READ_ONLY_OPTIMAL
  gpu.image_barrier(
    command_buffer,
    position_texture.image,
    .COLOR_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    normal_texture.image,
    .COLOR_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    albedo_texture.image,
    .COLOR_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    metallic_roughness_texture.image,
    .COLOR_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.COLOR},
  )
  gpu.image_barrier(
    command_buffer,
    emissive_texture.image,
    .COLOR_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.COLOR},
  )
}

render :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
  command_stride: u32,
) {
  if draw_buffer == 0 || count_buffer == 0 {
    return
  }
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    rm.geometry_pipeline_layout,
    rm.camera_buffer_descriptor_sets[frame_index], // Per-frame to avoid overlap
    rm.textures_descriptor_set,
    rm.bone_buffer_descriptor_set,
    rm.material_buffer_descriptor_set,
    rm.world_matrix_descriptor_set,
    rm.node_data_descriptor_set,
    rm.mesh_data_descriptor_set,
    rm.vertex_skinning_descriptor_set,
  )
  push_constants := PushConstant {
    camera_index = camera_handle.index,
  }
  vk.CmdPushConstants(
    command_buffer,
    rm.geometry_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  gpu.bind_vertex_index_buffers(
    command_buffer,
    rm.vertex_buffer.buffer,
    rm.index_buffer.buffer,
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

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  gpu.free_command_buffer(gctx, ..self.commands[:])
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  camera_handle: resources.Handle,
  rm: ^resources.Manager,
) -> (
  command_buffer: vk.CommandBuffer,
  ret: vk.Result,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil {
    ret = .ERROR_UNKNOWN
    return
  }
  command_buffer = camera.geometry_commands[frame_index]
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
    rasterizationSamples    = {._1}, // No MSAA, single sample per pixel
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
  rm: ^resources.Manager,
  frame_index: u32,
) -> vk.Result {
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}
