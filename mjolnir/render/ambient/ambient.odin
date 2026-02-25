package ambient

import "../../gpu"
import d "../data"
import rg "../graph"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../shader/lighting_ambient/vert.spv")
SHADER_FRAG :: #load("../../shader/lighting_ambient/frag.spv")
TEXTURE_LUT_GGX :: #load("../../assets/lut_ggx.png")

PushConstant :: struct {
  camera_index:           u32,
  environment_index:      u32,
  brdf_lut_index:         u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  environment_max_lod:    f32,
  ibl_intensity:          f32,
}

Renderer :: struct {
  pipeline:                vk.Pipeline,
  pipeline_layout:         vk.PipelineLayout,
  environment_map:         gpu.Texture2DHandle,
  brdf_lut:                gpu.Texture2DHandle,
  environment_max_lod:     f32,
  ibl_intensity:           f32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debug("Ambient lighting renderer init")
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.FRAGMENT},
      size = size_of(PushConstant),
    },
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }
  vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.COLOR_ONLY_RENDERING_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &gpu.VERTEX_INPUT_NONE,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_OVERRIDE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  }
  log.info("Ambient lighting pipeline initialized successfully")
  return .SUCCESS
}

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) -> (
  ret: vk.Result,
) {
  env_map, env_result := gpu.create_texture_2d_from_path(
    gctx,
    texture_manager,
    "assets/Cannon_Exterior.hdr",
    .R32G32B32A32_SFLOAT,
    true,
    {.SAMPLED},
    true,
  )
  if env_result == .SUCCESS {
    self.environment_map = env_map
  } else {
    log.warn("HDR environment map not found, using default ambient lighting")
    self.environment_map = {}
  }
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, self.environment_map)
  }
  environment_map := gpu.get_texture_2d(texture_manager, self.environment_map)
  if environment_map != nil {
    self.environment_max_lod =
      f32(
        gpu.calculate_mip_levels(
          environment_map.spec.width,
          environment_map.spec.height,
        ),
      ) -
      1.0
  } else {
    self.environment_max_lod = 0.0
  }
  brdf_handle := gpu.create_texture_2d_from_data(
    gctx,
    texture_manager,
    TEXTURE_LUT_GGX,
  ) or_return
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, brdf_handle)
  }
  self.brdf_lut = brdf_handle
  self.ibl_intensity = 1.0
  log.info("Ambient lighting GPU resources setup")
  return .SUCCESS
}

teardown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  gpu.free_texture_2d(texture_manager, gctx, self.environment_map)
  self.environment_map = {}
  gpu.free_texture_2d(texture_manager, gctx, self.brdf_lut)
  self.brdf_lut = {}
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

// ============================================================================
// Graph-based API for render graph integration
// ============================================================================

Blackboard :: struct {
  final_image: rg.Texture,
  position:    rg.Texture,
  normal:      rg.Texture,
  albedo:      rg.Texture,
  metallic:    rg.Texture,
  emissive:    rg.Texture,
  cameras_descriptor_set:  vk.DescriptorSet,
  textures_descriptor_set: vk.DescriptorSet,
}

ambient_pass_deps_from_context :: proc(
  pass_ctx: ^rg.PassContext,
) -> Blackboard {
  return Blackboard {
    final_image = rg.get_texture(pass_ctx, .CAMERA_FINAL_IMAGE),
    position = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_POSITION),
    normal = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_NORMAL),
    albedo = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_ALBEDO),
    metallic = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_METALLIC_ROUGHNESS),
    emissive = rg.get_texture(pass_ctx, .CAMERA_GBUFFER_EMISSIVE),
  }
}

ambient_pass_execute :: proc(
  self: ^Renderer,
  pass_ctx: ^rg.PassContext,
  deps: Blackboard,
) {

  final_image_handle := deps.final_image
  position_handle := deps.position
  normal_handle := deps.normal
  albedo_handle := deps.albedo
  metallic_handle := deps.metallic
  emissive_handle := deps.emissive

  // Create color attachment info manually
  color_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = final_image_handle.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR, // Clear since this is the first pass to render to final_image
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 0.0}}},
  }

  // Begin rendering to final_image
  rendering_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = final_image_handle.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
  }

  vk.CmdBeginRendering(pass_ctx.cmd, &rendering_info)

  gpu.set_viewport_scissor(
    pass_ctx.cmd,
    final_image_handle.extent,
    flip_y = false,
  )

  gpu.bind_graphics_pipeline(
    pass_ctx.cmd,
    self.pipeline,
    self.pipeline_layout,
    deps.cameras_descriptor_set,
    deps.textures_descriptor_set,
  )

  // Build push constants using camera attachment texture indices
  push := PushConstant {
    camera_index           = pass_ctx.scope_index,
    environment_index      = self.environment_map.index,
    brdf_lut_index         = self.brdf_lut.index,
    position_texture_index = position_handle.index,
    normal_texture_index   = normal_handle.index,
    albedo_texture_index   = albedo_handle.index,
    metallic_texture_index = metallic_handle.index,
    emissive_texture_index = emissive_handle.index,
    environment_max_lod    = self.environment_max_lod,
    ibl_intensity          = self.ibl_intensity,
  }

  vk.CmdPushConstants(
    pass_ctx.cmd,
    self.pipeline_layout,
    {.FRAGMENT},
    0,
    size_of(PushConstant),
    &push,
  )

  vk.CmdDraw(pass_ctx.cmd, 3, 1, 0, 0) // fullscreen triangle
  vk.CmdEndRendering(pass_ctx.cmd)
}
