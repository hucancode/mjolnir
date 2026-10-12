#+private
package render

import vk "vendor:vulkan"

TEXTURE_LUT_GGX :: #load("assets/lut_ggx.png")

// The environment light's data, drawn as the AMBIENT light. ibl_intensity
// scales image-based lighting; skybox_intensity 0 hides the skybox.
AmbientRenderer :: struct {
  environment_map:  TextureHandle,
  brdf_lut:         TextureHandle,
  // precomputed from environment_map
  irradiance_cube:  TextureHandle,
  prefilter_cube:   TextureHandle,
  ibl_intensity:    f32,
  skybox_intensity: f32,
  skybox_blur:      f32,
}

ambient_setup :: proc(r: ^Manager) -> vk.Result {
  self := &r.ambient
  self.brdf_lut = create_texture_from_data(r, TEXTURE_LUT_GGX) or_return
  self.ibl_intensity = 1.0
  self.skybox_intensity = 1.0
  self.skybox_blur = 0.25
  return .SUCCESS
}

// Replace the environment map with the equirectangular HDR image at `path`
// and precompute IBL from it. Without an environment map IBL and the skybox
// are black.
ambient_load_environment :: proc(r: ^Manager, path: string) -> (ret: vk.Result) {
  self := &r.ambient
  ambient_free_environment(r)
  defer if ret != .SUCCESS do ambient_free_environment(r)
  self.environment_map = create_texture_from_path(r, path, .R32G32B32A32_SFLOAT, true) or_return
  self.irradiance_cube, self.prefilter_cube = ambient_precompute(r, self.environment_map) or_return
  return .SUCCESS
}

@(private = "file")
ambient_free_environment :: proc(r: ^Manager) {
  self := &r.ambient
  destroy_texture(r, self.environment_map)
  destroy_texture(r, self.irradiance_cube)
  destroy_texture(r, self.prefilter_cube)
  self.environment_map, self.irradiance_cube, self.prefilter_cube = {}, {}, {}
}

// The textures go with the level's textures.
ambient_teardown :: proc(r: ^Manager) {
  r.ambient.environment_map, r.ambient.irradiance_cube, r.ambient.prefilter_cube, r.ambient.brdf_lut = {}, {}, {}, {}
}
