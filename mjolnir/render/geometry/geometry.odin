package geometry_pass

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import d "../data"
import rg "../graph"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_G_BUFFER_VERT :: #load("../../shader/gbuffer/vert.spv")
SHADER_G_BUFFER_FRAG :: #load("../../shader/gbuffer/frag.spv")

PushConstant :: struct {
  camera_index: u32,
}

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
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

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

//
// Render Graph Integration
//

Blackboard :: struct {
  depth:              rg.DepthTexture,
  position:           rg.Texture,
  normal:             rg.Texture,
  albedo:             rg.Texture,
  metallic_roughness: rg.Texture,
  emissive:           rg.Texture,
  draw_commands:      rg.Buffer,
  draw_count:         rg.Buffer,
  cameras_descriptor_set:         vk.DescriptorSet,
  textures_descriptor_set:        vk.DescriptorSet,
  bone_descriptor_set:            vk.DescriptorSet,
  material_descriptor_set:        vk.DescriptorSet,
  node_data_descriptor_set:       vk.DescriptorSet,
  mesh_data_descriptor_set:       vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer:                  vk.Buffer,
  index_buffer:                   vk.Buffer,
}

geometry_pass_deps_from_context :: proc(
  pass_ctx: ^rg.PassContext,
) -> Blackboard {
  return Blackboard {
    depth = rg.get_depth(pass_ctx, .CAMERA_DEPTH),
    position = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_POSITION),
    normal = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_NORMAL),
    albedo = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_ALBEDO),
    metallic_roughness = rg.get_texture(
      pass_ctx,
      .CAMERA_GBUFFER_METALLIC_ROUGHNESS,
    ),
    emissive = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_EMISSIVE),
    draw_commands = rg.get_buffer(pass_ctx, .CAMERA_OPAQUE_DRAW_COMMANDS),
    draw_count = rg.get_buffer(pass_ctx, .CAMERA_OPAQUE_DRAW_COUNT),
  }
}

geometry_pass_execute :: proc(
  self: ^Renderer,
  pass_ctx: ^rg.PassContext,
  deps: Blackboard,
) {
  cam_idx := pass_ctx.scope_index

  depth_handle := deps.depth
  position_handle := deps.position
  normal_handle := deps.normal
  albedo_handle := deps.albedo
  metallic_roughness_handle := deps.metallic_roughness
  emissive_handle := deps.emissive
  draw_cmd_handle := deps.draw_commands
  draw_count_handle := deps.draw_count

  // Create color attachments (UNDEFINED → COLOR_ATTACHMENT_OPTIMAL handled by graph)
  color_attachments := [5]vk.RenderingAttachmentInfo {
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
  depth_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = depth_handle.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  // Begin rendering
  rendering_info := vk.RenderingInfo {
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
    self.pipeline,
    self.pipeline_layout,
    deps.cameras_descriptor_set,
    deps.textures_descriptor_set,
    deps.bone_descriptor_set,
    deps.material_descriptor_set,
    deps.node_data_descriptor_set,
    deps.mesh_data_descriptor_set,
    deps.vertex_skinning_descriptor_set,
  )

  // Push constants
  push_constants := PushConstant {
    camera_index = u32(cam_idx),
  }
  vk.CmdPushConstants(
    pass_ctx.cmd,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )

  // Bind vertex and index buffers
  gpu.bind_vertex_index_buffers(
    pass_ctx.cmd,
    deps.vertex_buffer,
    deps.index_buffer,
  )

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
