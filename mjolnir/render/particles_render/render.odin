package particles_render

import "../../gpu"
import rd "../data"
import rg "../graph"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_PARTICLE_VERT := #load("../../shader/particle/vert.spv")
SHADER_PARTICLE_FRAG := #load("../../shader/particle/frag.spv")
TEXTURE_BLACK_CIRCLE :: #load("../../assets/black-circle.png")

Particle :: rd.Particle

Renderer :: struct {
  render_pipeline_layout: vk.PipelineLayout,
  render_pipeline:        vk.Pipeline,
  default_texture_index:  u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debugf("Initializing particle render renderer")

  default_texture_handle := gpu.create_texture_2d_from_data(
    gctx,
    texture_manager,
    TEXTURE_BLACK_CIRCLE,
  ) or_return
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, default_texture_handle)
  }
  self.default_texture_index = default_texture_handle.index

  create_render_pipeline(
    gctx,
    self,
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
    vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
  }

  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
}

create_render_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.render_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(u32)},
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
  }

  vertex_binding := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Particle),
    inputRate = .VERTEX,
  }

  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, position)),
    },
    {
      location = 1,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, color)),
    },
    {
      location = 2,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Particle, size)),
    },
    {
      location = 3,
      binding = 0,
      format = .R32_UINT,
      offset = u32(offset_of(Particle, texture_index)),
    },
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }

  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_PARTICLE_VERT,
  ) or_return
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_PARTICLE_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

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
    pInputAssemblyState = &gpu.POINT_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    layout              = self.render_pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }

  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.render_pipeline,
  ) or_return

  return .SUCCESS
}

begin_pass :: proc(
  self: ^Renderer,
  _command_buffer: vk.CommandBuffer,
  _camera: rawptr,
  _texture_manager: rawptr,
  _frame_index: u32,
) {
  _ = self
}

render :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  cameras_descriptor_set: vk.DescriptorSet,
  textures_descriptor_set: vk.DescriptorSet,
  compact_particle_buffer: vk.Buffer,
  draw_command_buffer: vk.Buffer,
) {
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.render_pipeline,
    self.render_pipeline_layout,
    cameras_descriptor_set,
    textures_descriptor_set,
  )

  camera_idx := camera_index
  vk.CmdPushConstants(
    command_buffer,
    self.render_pipeline_layout,
    {.VERTEX},
    0,
    size_of(u32),
    &camera_idx,
  )

  offset: vk.DeviceSize = 0
  buffer := compact_particle_buffer
  vk.CmdBindVertexBuffers(command_buffer, 0, 1, &buffer, &offset)

  vk.CmdDrawIndirect(
    command_buffer,
    draw_command_buffer,
    0,
    1,
    size_of(vk.DrawIndirectCommand),
  )
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

// ====== GRAPH-BASED API ======

Blackboard :: struct {
  compact_buffer: rg.Buffer,
  draw_commands:  rg.Buffer,
  depth:          rg.DepthTexture,
  final_image:    rg.Texture,
  camera_descriptor_set:   vk.DescriptorSet,
  textures_descriptor_set: vk.DescriptorSet,
}

particles_render_pass_deps_from_context :: proc(
  ctx: ^rg.PassContext,
) -> Blackboard {
  return Blackboard {
    compact_buffer = rg.get_buffer(ctx, .COMPACT_PARTICLE_BUFFER),
    draw_commands = rg.get_buffer(ctx, .DRAW_COMMAND_BUFFER),
    depth = rg.get_depth(ctx, .CAMERA_DEPTH),
    final_image = rg.get_texture(ctx, .CAMERA_FINAL_IMAGE),
  }
}

// Execute phase: render with resolved resources
particles_render_execute :: proc(
  self: ^Renderer,
  ctx: ^rg.PassContext,
  deps: Blackboard,
) {
  cam_idx := ctx.scope_index

  compact_buf_handle := deps.compact_buffer
  draw_cmd_handle := deps.draw_commands
  depth_handle := deps.depth
  final_image_handle := deps.final_image

  // Begin rendering
  depth_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = depth_handle.view,
    imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  color_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = final_image_handle.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  rendering_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {
      extent = {
        final_image_handle.extent.width,
        final_image_handle.extent.height,
      },
    },
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }

  vk.CmdBeginRendering(ctx.cmd, &rendering_info)

  // Set viewport and scissor
  gpu.set_viewport_scissor(ctx.cmd, final_image_handle.extent)

  // Bind pipeline and descriptor sets
  gpu.bind_graphics_pipeline(
    ctx.cmd,
    self.render_pipeline,
    self.render_pipeline_layout,
    deps.camera_descriptor_set,
    deps.textures_descriptor_set,
  )

  // Push camera index constant
  camera_idx_push := cam_idx
  vk.CmdPushConstants(
    ctx.cmd,
    self.render_pipeline_layout,
    {.VERTEX},
    0,
    size_of(u32),
    &camera_idx_push,
  )

  // Bind vertex buffer (compact particle buffer)
  offset: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(ctx.cmd, 0, 1, &compact_buf_handle.buffer, &offset)

  // Draw indirect
  vk.CmdDrawIndirect(
    ctx.cmd,
    draw_cmd_handle.buffer,
    0,
    1,
    size_of(vk.DrawIndirectCommand),
  )

  vk.CmdEndRendering(ctx.cmd)
}
