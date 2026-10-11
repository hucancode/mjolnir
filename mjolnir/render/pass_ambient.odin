#+private
package render

import "gpu"
import "core:log"
import vk "vendor:vulkan"

// The post-process fullscreen triangle.
AMBIENT_SHADER_VERT :: #load("shader/postprocess/vert.spv")
AMBIENT_SHADER_FRAG :: #load("shader/lighting_ambient/frag.spv")
TEXTURE_LUT_GGX :: #load("assets/lut_ggx.png")

AmbientPushConstant :: struct {
  camera_index:           u32,
  irradiance_index:       u32,
  prefilter_index:        u32,
  brdf_lut_index:         u32,
  environment_index:      u32,
  depth_texture_index:    u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  ibl_intensity:          f32,
  skybox_intensity:       f32,
  skybox_blur:            f32,
  skybox_enabled:         u32,
}

AmbientRenderer :: struct {
  pipeline:             vk.Pipeline,
  pipeline_layout:      vk.PipelineLayout,
  environment_map:      Texture2DHandle,
  brdf_lut:             Texture2DHandle,
  ibl:                  IBLResults,
  ibl_intensity:        f32,
  skybox_enabled:       bool,
  skybox_intensity:     f32,
  skybox_blur:          f32,
}

ambient_init :: proc(
  self: ^AmbientRenderer,
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
      size = size_of(AmbientPushConstant),
    },
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }
  color_formats := [?]vk.Format{gpu.HDR_COLOR_FORMAT}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_OVERRIDE}
  self.pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = AMBIENT_SHADER_VERT,
      frag = AMBIENT_SHADER_FRAG,
      specialization = &SHADER_SPEC_CONSTANTS,
      topology = .TRIANGLE_LIST,
      raster = gpu.DOUBLE_SIDED_RASTERIZER,
      blend = blend[:],
      color_formats = color_formats[:],
      // drawn inside the light-volume scope; no depth test
      depth_format = .D32_SFLOAT,
      layout = self.pipeline_layout,
    },
  ) or_return
  log.info("Ambient lighting pipeline initialized successfully")
  return .SUCCESS
}

ambient_setup :: proc(
  self: ^AmbientRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
) -> vk.Result {
  self.brdf_lut = create_texture_2d_from_data(
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
// and ambient_precompute IBL from it. Without an environment map IBL and the skybox
// are black.
ambient_load_environment :: proc(
  self: ^AmbientRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  path: string,
) -> (
  ret: vk.Result,
) {
  ambient_free_environment(self, gctx, texture_manager)
  self.environment_map = create_texture_2d_from_path(
    gctx,
    texture_manager,
    path,
    .R32G32B32A32_SFLOAT,
    true,
  ) or_return
  defer if ret != .SUCCESS do ambient_free_environment(self, gctx, texture_manager)
  self.ibl = ambient_precompute(
    gctx,
    texture_manager,
    self.environment_map,
    texture_manager.samplers[.LINEAR_REPEAT],
  ) or_return
  return .SUCCESS
}

@(private = "file")
ambient_free_environment :: proc(
  self: ^AmbientRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
) {
  ambient_free_results(gctx, texture_manager, &self.ibl)
  free_texture_2d(texture_manager, gctx, self.environment_map)
  self.environment_map = {}
}

ambient_teardown :: proc(
  self: ^AmbientRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
) {
  ambient_free_environment(self, gctx, texture_manager)
  free_texture_2d(texture_manager, gctx, self.brdf_lut)
  self.brdf_lut = {}
}

ambient_shutdown :: proc(self: ^AmbientRenderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

TEX_INDEX_INVALID :: u32(0xFFFFFFFF)

@(private = "file")
ambient_tex_index :: proc(h: $H) -> u32 {
  return h.index if h.generation != 0 else TEX_INDEX_INVALID
}

// Fullscreen IBL + skybox draw, the first draw of the lighting scope.
ambient_draw :: proc(
  r: ^Manager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  camera_handle: u32,
  gbuffer: GBuffer,
) {
  self := &r.ambient
  gpu.bind_pipeline(
    command_buffer,
    .GRAPHICS,
    self.pipeline,
    self.pipeline_layout,
    r.internal.camera_buffer.descriptor_sets[frame_index],
    r.texture_manager.descriptor_set,
  )
  push := AmbientPushConstant {
    camera_index           = camera_handle,
    irradiance_index       = ambient_tex_index(self.ibl.irradiance_cube),
    prefilter_index        = ambient_tex_index(self.ibl.prefilter_cube),
    brdf_lut_index         = ambient_tex_index(self.brdf_lut),
    environment_index      = ambient_tex_index(self.environment_map),
    depth_texture_index    = gbuffer.depth,
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
    size_of(AmbientPushConstant),
    &push,
  )
  vk.CmdDraw(command_buffer, 3, 1, 0, 0)
}
