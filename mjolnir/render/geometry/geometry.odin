package geometry_pass

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../camera"
import d "../data"
import rg "../graph"
import "../shared"
import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

SHADER_G_BUFFER_VERT :: #load("../../shader/gbuffer/vert.spv")
SHADER_G_BUFFER_FRAG :: #load("../../shader/gbuffer/frag.spv")

PushConstant :: struct {
  camera_index: u32,
}

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:         vk.Pipeline,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  width, height: u32,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
  bone_set_layout: vk.DescriptorSetLayout,
  material_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  mesh_data_set_layout: vk.DescriptorSetLayout,
  vertex_skinning_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  depth_format: vk.Format = .D32_SFLOAT
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    camera_set_layout,
    textures_set_layout,
    bone_set_layout,
    material_set_layout,
    node_data_set_layout,
    mesh_data_set_layout,
    vertex_skinning_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
    self.pipeline_layout = 0
  }
  if self.pipeline_layout == 0 {
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
    layout              = self.pipeline_layout,
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
  camera: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  // Transition all G-buffer textures to COLOR_ATTACHMENT_OPTIMAL
  position_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.POSITION][frame_index],
  )
  normal_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.NORMAL][frame_index],
  )
  albedo_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.ALBEDO][frame_index],
  )
  metallic_roughness_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.METALLIC_ROUGHNESS][frame_index],
  )
  emissive_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.EMISSIVE][frame_index],
  )
  final_texture := gpu.get_texture_2d(
    texture_manager,
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
  depth_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.DEPTH][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    depth_texture.spec.extent,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(position_texture),
    gpu.create_color_attachment(normal_texture),
    gpu.create_color_attachment(albedo_texture),
    gpu.create_color_attachment(metallic_roughness_texture),
    gpu.create_color_attachment(emissive_texture),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    depth_texture.spec.extent,
  )
}

end_pass :: proc(
  camera: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  vk.CmdEndRendering(command_buffer)
  // transition all G-buffer textures to SHADER_READ_ONLY_OPTIMAL for use by lighting and post-processing
  position_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.POSITION][frame_index],
  )
  normal_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.NORMAL][frame_index],
  )
  albedo_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.ALBEDO][frame_index],
  )
  metallic_roughness_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.METALLIC_ROUGHNESS][frame_index],
  )
  emissive_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.EMISSIVE][frame_index],
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
  camera: ^camera.Camera,
  camera_handle: u32,
  frame_index: u32,
  command_buffer: vk.CommandBuffer,
  cameras_descriptor_set: vk.DescriptorSet,
  textures_descriptor_set: vk.DescriptorSet,
  bone_descriptor_set: vk.DescriptorSet,
  material_descriptor_set: vk.DescriptorSet,
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
    self.pipeline_layout,
    cameras_descriptor_set,
    textures_descriptor_set,
    bone_descriptor_set,
    material_descriptor_set,
    node_data_descriptor_set,
    mesh_data_descriptor_set,
    vertex_skinning_descriptor_set,
  )
  push_constants := PushConstant {
    camera_index = camera_handle,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
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
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

//
// Render Graph Integration
//

GeometryPassGraphContext :: struct {
  renderer:                      ^Renderer,
  texture_manager:               ^gpu.TextureManager,
  cameras_descriptor_set:        vk.DescriptorSet,
  textures_descriptor_set:       vk.DescriptorSet,
  bone_descriptor_set:           vk.DescriptorSet,
  material_descriptor_set:       vk.DescriptorSet,
  node_data_descriptor_set:      vk.DescriptorSet,
  mesh_data_descriptor_set:      vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer:                 vk.Buffer,
  index_buffer:                  vk.Buffer,
}

// REMOVED: Old setup callback (replaced by declarative PassTemplate)

geometry_pass_execute :: proc(pass_ctx: ^rg.PassContext, user_data: rawptr) {
  ctx := cast(^GeometryPassGraphContext)user_data
  cam_idx := pass_ctx.scope_index

  // Resolve depth texture
  depth_id := rg.ResourceId(fmt.tprintf("camera_%d_depth", cam_idx))
  depth_handle, depth_ok := rg.resolve(rg.DepthTextureHandle, pass_ctx, depth_id)
  if !depth_ok do return

  // Resolve G-buffer textures
  position_id := rg.ResourceId(fmt.tprintf("camera_%d_gbuffer_position", cam_idx))
  position_handle, position_ok := rg.resolve(rg.TextureHandle, pass_ctx, position_id)
  if !position_ok do return

  normal_id := rg.ResourceId(fmt.tprintf("camera_%d_gbuffer_normal", cam_idx))
  normal_handle, normal_ok := rg.resolve(rg.TextureHandle, pass_ctx, normal_id)
  if !normal_ok do return

  albedo_id := rg.ResourceId(fmt.tprintf("camera_%d_gbuffer_albedo", cam_idx))
  albedo_handle, albedo_ok := rg.resolve(rg.TextureHandle, pass_ctx, albedo_id)
  if !albedo_ok do return

  metallic_roughness_id := rg.ResourceId(fmt.tprintf("camera_%d_gbuffer_metallic_roughness", cam_idx))
  metallic_roughness_handle, metallic_roughness_ok := rg.resolve(rg.TextureHandle, pass_ctx, metallic_roughness_id)
  if !metallic_roughness_ok do return

  emissive_id := rg.ResourceId(fmt.tprintf("camera_%d_gbuffer_emissive", cam_idx))
  emissive_handle, emissive_ok := rg.resolve(rg.TextureHandle, pass_ctx, emissive_id)
  if !emissive_ok do return

  // Resolve draw buffers
  draw_cmd_id := rg.ResourceId(fmt.tprintf("camera_%d_opaque_draw_commands", cam_idx))
  draw_cmd_handle, draw_cmd_ok := rg.resolve(rg.BufferHandle, pass_ctx, draw_cmd_id)
  if !draw_cmd_ok do return

  draw_count_id := rg.ResourceId(fmt.tprintf("camera_%d_opaque_draw_count", cam_idx))
  draw_count_handle, draw_count_ok := rg.resolve(rg.BufferHandle, pass_ctx, draw_count_id)
  if !draw_count_ok do return

  if draw_cmd_handle.buffer == 0 || draw_count_handle.buffer == 0 {
    return
  }

  // Create color attachments (UNDEFINED → COLOR_ATTACHMENT_OPTIMAL handled by graph)
  color_attachments := [5]vk.RenderingAttachmentInfo{
    {
      sType = .RENDERING_ATTACHMENT_INFO,
      imageView = position_handle.view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
    },
    {
      sType = .RENDERING_ATTACHMENT_INFO,
      imageView = normal_handle.view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
    },
    {
      sType = .RENDERING_ATTACHMENT_INFO,
      imageView = albedo_handle.view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
    },
    {
      sType = .RENDERING_ATTACHMENT_INFO,
      imageView = metallic_roughness_handle.view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
    },
    {
      sType = .RENDERING_ATTACHMENT_INFO,
      imageView = emissive_handle.view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
    },
  }

  // Create depth attachment (already in correct state from depth prepass)
  depth_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_handle.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,
    storeOp = .STORE,
  }

  // Begin rendering
  rendering_info := vk.RenderingInfo{
    sType = .RENDERING_INFO,
    renderArea = {extent = depth_handle.extent},
    layerCount = 1,
    colorAttachmentCount = len(color_attachments),
    pColorAttachments = raw_data(color_attachments[:]),
    pDepthAttachment = &depth_attachment,
  }

  vk.CmdBeginRendering(pass_ctx.cmd, &rendering_info)

  // Set viewport and scissor
  gpu.set_viewport_scissor(pass_ctx.cmd, depth_handle.extent)

  // Bind pipeline and descriptor sets
  gpu.bind_graphics_pipeline(
    pass_ctx.cmd,
    ctx.renderer.pipeline,
    ctx.renderer.pipeline_layout,
    ctx.cameras_descriptor_set,
    ctx.textures_descriptor_set,
    ctx.bone_descriptor_set,
    ctx.material_descriptor_set,
    ctx.node_data_descriptor_set,
    ctx.mesh_data_descriptor_set,
    ctx.vertex_skinning_descriptor_set,
  )

  // Push constants
  push_constants := PushConstant{
    camera_index = u32(cam_idx),
  }
  vk.CmdPushConstants(
    pass_ctx.cmd,
    ctx.renderer.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )

  // Bind vertex and index buffers
  gpu.bind_vertex_index_buffers(pass_ctx.cmd, ctx.vertex_buffer, ctx.index_buffer)

  // Draw indirect
  vk.CmdDrawIndexedIndirectCount(
    pass_ctx.cmd,
    draw_cmd_handle.buffer,
    0,
    draw_count_handle.buffer,
    0,
    d.MAX_NODES_IN_SCENE,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )

  vk.CmdEndRendering(pass_ctx.cmd)

  // Graph will automatically transition G-buffer textures to SHADER_READ_ONLY_OPTIMAL
}
