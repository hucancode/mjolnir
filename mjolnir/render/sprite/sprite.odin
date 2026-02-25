package sprite

import "../../geometry"
import "../../gpu"
import d "../data"
import rg "../graph"
import vk "vendor:vulkan"

SHADER_SPRITE_VERT :: #load("../../shader/sprite/vert.spv")
SHADER_SPRITE_FRAG :: #load("../../shader/sprite/frag.spv")

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
}

PushConstant :: struct {
  camera_index: u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  sprite_set_layout: vk.DescriptorSetLayout,
) -> vk.Result {
  // Create pipeline layout (4 descriptor sets)
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    camera_set_layout,
    textures_set_layout,
    node_data_set_layout,
    sprite_set_layout,
  ) or_return

  // Create shader modules
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_SPRITE_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_SPRITE_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

  // Create pipeline
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
  shader_stages := gpu.create_vert_frag_stages(vert_module, frag_module)
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return

  return .SUCCESS
}

destroy :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

render :: proc(
  self: ^Renderer,
  cmd: vk.CommandBuffer,
  camera_index: u32,
  camera_set: vk.DescriptorSet,
  textures_set: vk.DescriptorSet,
  node_data_set: vk.DescriptorSet,
  sprite_set: vk.DescriptorSet,
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
  max_draw_count: u32,
) {
  // Bind pipeline (4 descriptor sets)
  gpu.bind_graphics_pipeline(
    cmd,
    self.pipeline,
    self.pipeline_layout,
    camera_set,
    textures_set,
    node_data_set,
    sprite_set,
  )

  // Push constants
  push_constants := PushConstant {
    camera_index = camera_index,
  }
  vk.CmdPushConstants(
    cmd,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )

  // Bind vertex/index buffers
  vertex_buffers := [?]vk.Buffer{vertex_buffer}
  vertex_offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    cmd,
    0,
    1,
    raw_data(vertex_buffers[:]),
    raw_data(vertex_offsets[:]),
  )
  vk.CmdBindIndexBuffer(cmd, index_buffer, 0, .UINT32)

  // Draw
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    draw_buffer,
    0,
    count_buffer,
    0,
    max_draw_count,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
}

begin_sprite_rendering :: proc(
  cmd: vk.CommandBuffer,
  final_image: rg.Texture,
  depth: rg.DepthTexture,
) {
  color_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = final_image.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  depth_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = depth.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  rendering_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = final_image.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }

  vk.CmdBeginRendering(cmd, &rendering_info)
  gpu.set_viewport_scissor(cmd, final_image.extent)
}

Blackboard :: struct {
  final_image:   rg.Texture,
  depth:         rg.DepthTexture,
  draw_commands: rg.Buffer,
  draw_count:    rg.Buffer,
  cameras_descriptor_set:   vk.DescriptorSet,
  textures_descriptor_set:  vk.DescriptorSet,
  node_data_descriptor_set: vk.DescriptorSet,
  sprite_descriptor_set:    vk.DescriptorSet,
  vertex_buffer:            vk.Buffer,
  index_buffer:             vk.Buffer,
}

sprite_render_pass_deps_from_context :: proc(
  pass_ctx: ^rg.PassContext,
) -> Blackboard {
  return Blackboard {
    final_image = rg.get_texture(pass_ctx, .CAMERA_FINAL_IMAGE),
    depth = rg.get_depth(pass_ctx, .CAMERA_DEPTH),
    draw_commands = rg.get_buffer(pass_ctx, .CAMERA_SPRITE_DRAW_COMMANDS),
    draw_count = rg.get_buffer(pass_ctx, .CAMERA_SPRITE_DRAW_COUNT),
  }
}

sprite_render_pass_execute :: proc(
  self: ^Renderer,
  pass_ctx: ^rg.PassContext,
  deps: Blackboard,
) {
  cmd := pass_ctx.cmd
  cam_idx := pass_ctx.scope_index
  final_image_handle := deps.final_image
  depth_handle := deps.depth
  draw_cmd_handle := deps.draw_commands
  draw_count_handle := deps.draw_count

  begin_sprite_rendering(cmd, final_image_handle, depth_handle)
  render(
    self,
    cmd,
    cam_idx,
    deps.cameras_descriptor_set,
    deps.textures_descriptor_set,
    deps.node_data_descriptor_set,
    deps.sprite_descriptor_set,
    deps.vertex_buffer,
    deps.index_buffer,
    draw_cmd_handle.buffer,
    draw_count_handle.buffer,
    d.MAX_NODES_IN_SCENE,
  )
  vk.CmdEndRendering(cmd)
}
