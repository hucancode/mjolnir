package ambient

import "../../gpu"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../shader/lighting_ambient/vert.spv")
SHADER_FRAG :: #load("../../shader/lighting_ambient/frag.spv")
TEXTURE_LUT_GGX :: #load("../../assets/lut_ggx.png")

PushConstant :: struct {
  camera_index:           u32,
  irradiance_index:       u32,
  prefilter_index:        u32,
  brdf_lut_index:         u32,
  environment_index:      u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  prefilter_max_lod:      f32,
  ibl_intensity:          f32,
  skybox_intensity:       f32,
  skybox_blur:            f32,
  skybox_enabled:         u32,
}

Renderer :: struct {
  pipeline:           vk.Pipeline,
  pipeline_layout:    vk.PipelineLayout,
  environment_map:    gpu.Texture2DHandle,
  brdf_lut:           gpu.Texture2DHandle,
  ibl:                IBLResults,
  ibl_intensity:      f32,
  skybox_enabled:     bool,
  skybox_intensity:   f32,
  skybox_blur:        f32,
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
    pNext               = &gpu.HDR_COLOR_ONLY_RENDERING_INFO,
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
  linear_repeat_sampler: vk.Sampler,
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
    log.warn("HDR environment map not found, IBL will fall back to black")
    self.environment_map = {}
  }
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, self.environment_map)
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
  self.skybox_enabled = true
  self.skybox_intensity = 1.0
  self.skybox_blur = 0.25

  if self.environment_map.index != 0 {
    self.ibl = precompute(
      gctx,
      texture_manager,
      self.environment_map,
      linear_repeat_sampler,
    ) or_return
  }

  log.info("Ambient lighting GPU resources setup")
  return .SUCCESS
}

teardown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  free_results(gctx, texture_manager, &self.ibl)
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

set_ibl_intensity :: proc(self: ^Renderer, intensity: f32) {
  self.ibl_intensity = max(intensity, 0.0)
}

set_skybox_enabled :: proc(self: ^Renderer, enabled: bool) {
  self.skybox_enabled = enabled
}

set_skybox_intensity :: proc(self: ^Renderer, intensity: f32) {
  self.skybox_intensity = max(intensity, 0.0)
}

set_skybox_blur :: proc(self: ^Renderer, blur: f32) {
  self.skybox_blur = clamp(blur, 0.0, 1.0)
}

record :: proc(
  self: ^Renderer,
  camera_handle: u32,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^gpu.TextureManager,
  final_image_handle: gpu.Texture2DHandle,
  cameras_descriptor_set: vk.DescriptorSet,
  position_texture_idx: u32,
  normal_texture_idx: u32,
  albedo_texture_idx: u32,
  metallic_texture_idx: u32,
  emissive_texture_idx: u32,
) {
  color_texture := gpu.get_texture_2d(texture_manager, final_image_handle)
  gpu.begin_rendering(
    command_buffer,
    color_texture.spec.extent,
    nil,
    gpu.create_color_attachment(color_texture),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    color_texture.spec.extent,
    flip_y = false,
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    cameras_descriptor_set,
    texture_manager.descriptor_set,
  )
  push := PushConstant {
    camera_index           = camera_handle,
    irradiance_index       = self.ibl.irradiance_cube.index,
    prefilter_index        = self.ibl.prefilter_cube.index,
    brdf_lut_index         = self.brdf_lut.index,
    environment_index      = self.environment_map.index,
    position_texture_index = position_texture_idx,
    normal_texture_index   = normal_texture_idx,
    albedo_texture_index   = albedo_texture_idx,
    metallic_texture_index = metallic_texture_idx,
    emissive_texture_index = emissive_texture_idx,
    prefilter_max_lod      = self.ibl.prefilter_max_lod,
    ibl_intensity          = self.ibl_intensity,
    skybox_intensity       = self.skybox_intensity,
    skybox_blur            = self.skybox_blur,
    skybox_enabled         = self.skybox_enabled ? 1 : 0,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.FRAGMENT},
    0,
    size_of(PushConstant),
    &push,
  )
  vk.CmdDraw(command_buffer, 3, 1, 0, 0)
  vk.CmdEndRendering(command_buffer)
}
