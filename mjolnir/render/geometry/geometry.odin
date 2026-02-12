package geometry_pass

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../camera"
import d "../data"
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
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  width, height: u32,
  general_pipeline_layout: vk.PipelineLayout,
) -> (
  ret: vk.Result,
) {
  depth_format: vk.Format = .D32_SFLOAT
  if general_pipeline_layout == 0 {
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
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
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
    layout              = general_pipeline_layout,
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
  camera_gpu: ^camera.CameraGPU,
  camera_cpu: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  // Transition all G-buffer textures to COLOR_ATTACHMENT_OPTIMAL
  position_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.POSITION][frame_index],
  )
  normal_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.NORMAL][frame_index],
  )
  albedo_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.ALBEDO][frame_index],
  )
  metallic_roughness_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.METALLIC_ROUGHNESS][frame_index],
  )
  emissive_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.EMISSIVE][frame_index],
  )
  final_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.FINAL_IMAGE][frame_index],
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
  depth_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.DEPTH][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    camera_cpu.extent[0],
    camera_cpu.extent[1],
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(position_texture),
    gpu.create_color_attachment(normal_texture),
    gpu.create_color_attachment(albedo_texture),
    gpu.create_color_attachment(metallic_roughness_texture),
    gpu.create_color_attachment(emissive_texture),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    camera_cpu.extent[0],
    camera_cpu.extent[1],
  )
}

end_pass :: proc(
  camera_gpu: ^camera.CameraGPU,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  vk.CmdEndRendering(command_buffer)
  // transition all G-buffer textures to SHADER_READ_ONLY_OPTIMAL for use by lighting and post-processing
  position_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.POSITION][frame_index],
  )
  normal_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.NORMAL][frame_index],
  )
  albedo_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.ALBEDO][frame_index],
  )
  metallic_roughness_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.METALLIC_ROUGHNESS][frame_index],
  )
  emissive_texture := gpu.get_texture_2d(
    texture_manager,
    camera_gpu.attachments[.EMISSIVE][frame_index],
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
  camera_gpu: ^camera.CameraGPU,
  camera_handle: d.CameraHandle,
  frame_index: u32,
  command_buffer: vk.CommandBuffer,
  general_pipeline_layout: vk.PipelineLayout,
  textures_descriptor_set: vk.DescriptorSet,
  bone_descriptor_set: vk.DescriptorSet,
  material_descriptor_set: vk.DescriptorSet,
  world_matrix_descriptor_set: vk.DescriptorSet,
  node_data_descriptor_set: vk.DescriptorSet,
  mesh_data_descriptor_set: vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
) {
  if draw_buffer == 0 || count_buffer == 0 {
    return
  }
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    general_pipeline_layout,
    camera_gpu.camera_buffer_descriptor_sets[frame_index],
    textures_descriptor_set,
    bone_descriptor_set,
    material_descriptor_set,
    world_matrix_descriptor_set,
    node_data_descriptor_set,
    mesh_data_descriptor_set,
    vertex_skinning_descriptor_set,
  )
  push_constants := PushConstant {
    camera_index = camera_handle.index,
  }
  vk.CmdPushConstants(
    command_buffer,
    general_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  gpu.bind_vertex_index_buffers(command_buffer, vertex_buffer, index_buffer)
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_buffer,
    0,
    count_buffer,
    0,
    d.MAX_NODES_IN_SCENE,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
}
