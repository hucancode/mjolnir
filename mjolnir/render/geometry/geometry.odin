package geometry_pass

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import d "../data"
import "../shared"
import rg "../graph"
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
    pDepthStencilState  = &gpu.READ_WRITE_DEPTH_STATE,
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
  position_handle: gpu.Texture2DHandle,
  normal_handle: gpu.Texture2DHandle,
  albedo_handle: gpu.Texture2DHandle,
  metallic_roughness_handle: gpu.Texture2DHandle,
  emissive_handle: gpu.Texture2DHandle,
  depth_handle: gpu.Texture2DHandle,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
) {
  position_texture := gpu.get_texture_2d(texture_manager, position_handle)
  normal_texture := gpu.get_texture_2d(texture_manager, normal_handle)
  albedo_texture := gpu.get_texture_2d(texture_manager, albedo_handle)
  metallic_roughness_texture := gpu.get_texture_2d(texture_manager, metallic_roughness_handle)
  emissive_texture := gpu.get_texture_2d(texture_manager, emissive_handle)
  depth_texture := gpu.get_texture_2d(texture_manager, depth_handle)
  gpu.begin_rendering(
    command_buffer,
    depth_texture.spec.extent,
    gpu.create_depth_attachment(depth_texture, .CLEAR, .STORE),
    gpu.create_color_attachment(position_texture),
    gpu.create_color_attachment(normal_texture),
    gpu.create_color_attachment(albedo_texture),
    gpu.create_color_attachment(metallic_roughness_texture),
    gpu.create_color_attachment(emissive_texture),
  )
  gpu.set_viewport_scissor(command_buffer, depth_texture.spec.extent)
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

render :: proc(
  self: ^Renderer,
  camera_handle: u32,
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

// Declare graph resources for the geometry pass.
// Creates G-buffer textures owned by the graph, and registers external
// depth + draw command buffers. Called from render.odin's setup callback.
declare_resources :: proc(setup: ^rg.PassSetup, extent: vk.Extent2D) {
  position_tex := rg.create_texture(setup, "gbuffer_position", rg.TextureDesc{
    width = extent.width, height = extent.height,
    format = .R32G32B32A32_SFLOAT,
    usage = {.COLOR_ATTACHMENT, .SAMPLED},
    aspect = {.COLOR},
  })
  normal_tex := rg.create_texture(setup, "gbuffer_normal", rg.TextureDesc{
    width = extent.width, height = extent.height,
    format = .R8G8B8A8_UNORM,
    usage = {.COLOR_ATTACHMENT, .SAMPLED},
    aspect = {.COLOR},
  })
  albedo_tex := rg.create_texture(setup, "gbuffer_albedo", rg.TextureDesc{
    width = extent.width, height = extent.height,
    format = .R8G8B8A8_UNORM,
    usage = {.COLOR_ATTACHMENT, .SAMPLED},
    aspect = {.COLOR},
  })
  metallic_roughness_tex := rg.create_texture(setup, "gbuffer_metallic_roughness", rg.TextureDesc{
    width = extent.width, height = extent.height,
    format = .R8G8B8A8_UNORM,
    usage = {.COLOR_ATTACHMENT, .SAMPLED},
    aspect = {.COLOR},
  })
  emissive_tex := rg.create_texture(setup, "gbuffer_emissive", rg.TextureDesc{
    width = extent.width, height = extent.height,
    format = .R8G8B8A8_UNORM,
    usage = {.COLOR_ATTACHMENT, .SAMPLED},
    aspect = {.COLOR},
  })
  final_image_tex := rg.create_texture(setup, "final_image", rg.TextureDesc{
    width = extent.width, height = extent.height,
    format = .R16G16B16A16_SFLOAT,
    usage = {.COLOR_ATTACHMENT, .SAMPLED},
    aspect = {.COLOR},
    // Non-main cameras double-buffer their output so the main camera can sample
    // the previous frame's result (frame N-1) while this camera renders frame N,
    // eliminating the data hazard on the shared image.
    double_buffer = setup.instance_idx > 0,
  })
  depth_tex := rg.register_external_texture(setup, "depth", rg.TextureDesc{
    width = extent.width, height = extent.height,
    format = .D32_SFLOAT,
    usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    aspect = {.DEPTH},
    is_external = true,
  })
  opaque_cmds := rg.register_external_buffer(setup, "opaque_draw_commands", rg.BufferDesc{
    size = 1024 * 1024,
    usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    is_external = true,
  })
  opaque_count := rg.register_external_buffer(setup, "opaque_draw_count", rg.BufferDesc{
    size = 4,
    usage = {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    is_external = true,
  })
  rg.reads_buffers(setup, opaque_cmds, opaque_count)
  rg.writes_textures(setup, position_tex, normal_tex, albedo_tex, metallic_roughness_tex, emissive_tex, final_image_tex, depth_tex)
}
