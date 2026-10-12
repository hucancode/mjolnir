#+private
package render

import "gpu"
import "core:log"
import vk "vendor:vulkan"

TEXTURE_LUT_GGX :: #load("assets/lut_ggx.png")

// The environment light's data, drawn as the AMBIENT light. ibl_intensity
// scales image-based lighting; skybox_intensity 0 hides the skybox.
AmbientRenderer :: struct {
  environment_map:  TextureHandle,
  brdf_lut:         TextureHandle,
  ibl:              IBLResults,
  ibl_intensity:    f32,
  skybox_intensity: f32,
  skybox_blur:      f32,
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
  layout: vk.PipelineLayout,
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
  self.ibl = ambient_precompute(gctx, texture_manager, layout, self.environment_map) or_return
  return .SUCCESS
}

@(private = "file")
ambient_free_environment :: proc(
  self: ^AmbientRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
) {
  ambient_free_results(gctx, texture_manager, &self.ibl)
  free_texture(texture_manager, gctx, self.environment_map)
  self.environment_map = {}
}

ambient_teardown :: proc(
  self: ^AmbientRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
) {
  ambient_free_environment(self, gctx, texture_manager)
  free_texture(texture_manager, gctx, self.brdf_lut)
  self.brdf_lut = {}
}
