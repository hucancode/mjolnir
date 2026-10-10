package ambient

import "../bindless"
import "../gpu"
import "core:log"
import vk "vendor:vulkan"

// The post-process fullscreen triangle.
@(private)
SHADER_VERT :: #load("../shader/postprocess/vert.spv")
@(private)
SHADER_FRAG :: #load("../shader/lighting_ambient/frag.spv")
@(private)
TEXTURE_LUT_GGX :: #load("../assets/lut_ggx.png")

@(private)
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
  ibl_intensity:          f32,
  skybox_intensity:       f32,
  skybox_blur:            f32,
  skybox_enabled:         u32,
}

Renderer :: struct {
  pipeline:             vk.Pipeline,
  pipeline_layout:      vk.PipelineLayout,
  environment_map:      bindless.Texture2DHandle,
  brdf_lut:             bindless.Texture2DHandle,
  ibl:                  IBLResults,
  ibl_intensity:        f32,
  skybox_enabled:       bool,
  skybox_intensity:     f32,
  skybox_blur:          f32,
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
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_OVERRIDE}
  self.pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = vert_module,
      frag = frag_module,
      specialization = &bindless.SHADER_SPEC_CONSTANTS,
      topology = .TRIANGLE_LIST,
      raster = gpu.DOUBLE_SIDED_RASTERIZER,
      blend = blend[:],
      color_formats = color_formats[:],
      layout = self.pipeline_layout,
    },
  ) or_return
  log.info("Ambient lighting pipeline initialized successfully")
  return .SUCCESS
}

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
) -> vk.Result {
  self.brdf_lut = bindless.create_texture_2d_from_data(
    gctx,
    texture_manager,
    TEXTURE_LUT_GGX,
  ) or_return
  self.ibl_intensity = 1.0
  self.skybox_enabled = true
  self.skybox_intensity = 1.0
  self.skybox_blur = 0.25
  log.info("Ambient lighting GPU resources setup")
  return .SUCCESS
}

// Replace the environment map with the equirectangular HDR image at `path`
// and precompute IBL from it. Without an environment map IBL and the skybox
// are black.
load_environment :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
  path: string,
) -> (
  ret: vk.Result,
) {
  free_environment(self, gctx, texture_manager)
  self.environment_map = bindless.create_texture_2d_from_path(
    gctx,
    texture_manager,
    path,
    .R32G32B32A32_SFLOAT,
    true,
    {.SAMPLED},
    true,
  ) or_return
  defer if ret != .SUCCESS do free_environment(self, gctx, texture_manager)
  self.ibl = precompute(
    gctx,
    texture_manager,
    self.environment_map,
    texture_manager.samplers[.LINEAR_REPEAT],
  ) or_return
  return .SUCCESS
}

@(private = "file")
free_environment :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
) {
  free_results(gctx, texture_manager, &self.ibl)
  bindless.free_texture_2d(texture_manager, gctx, self.environment_map)
  self.environment_map = {}
}

teardown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
) {
  free_environment(self, gctx, texture_manager)
  bindless.free_texture_2d(texture_manager, gctx, self.brdf_lut)
  self.brdf_lut = {}
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

@(private)
TEX_INDEX_INVALID :: u32(0xFFFFFFFF)

@(private = "file")
tex_index :: proc(h: $H) -> u32 {
  return h.index if h.generation != 0 else TEX_INDEX_INVALID
}

record :: proc(
  self: ^Renderer,
  camera_handle: u32,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^bindless.TextureManager,
  final_image_handle: bindless.Texture2DHandle,
  cameras_descriptor_set: vk.DescriptorSet,
  gbuffer: bindless.GBuffer,
) {
  color_texture := bindless.get_texture_2d(texture_manager, final_image_handle)
  gpu.begin_rendering(
    command_buffer,
    color_texture.extent,
    nil,
    gpu.create_color_attachment(color_texture.view),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    color_texture.extent,
    flip_y = false,
  )
  gpu.bind_pipeline(
    command_buffer,
    .GRAPHICS,
    self.pipeline,
    self.pipeline_layout,
    cameras_descriptor_set,
    texture_manager.descriptor_set,
  )
  push := PushConstant {
    camera_index           = camera_handle,
    irradiance_index       = tex_index(self.ibl.irradiance_cube),
    prefilter_index        = tex_index(self.ibl.prefilter_cube),
    brdf_lut_index         = tex_index(self.brdf_lut),
    environment_index      = tex_index(self.environment_map),
    position_texture_index = gbuffer.position,
    normal_texture_index   = gbuffer.normal,
    albedo_texture_index   = gbuffer.albedo,
    metallic_texture_index = gbuffer.metallic_roughness,
    emissive_texture_index = gbuffer.emissive,
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
