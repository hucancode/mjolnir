#+private
package render

@(private = "file")
TEXTURE_LUT_GGX :: #load("assets/lut_ggx.png")
// lights the scene until the application loads its own (environment_map_load)
@(private = "file")
DEFAULT_ENVIRONMENT :: #load("assets/environment2.hdr")

// face sizes of the image-based lighting cubes (pass_ibl.odin)
IRRADIANCE_SIZE :: 32
PREFILTER_SIZE :: 128

ambient_init :: proc(self: ^Renderer) -> bool {
  self.brdf_lut = texture_create(self, TEXTURE_LUT_GGX) or_return
  self.ibl_intensity = 1.0
  self.skybox_intensity = 1.0
  self.skybox_blur = 0.25
  return ambient_load_environment(self)
}

// The irradiance and prefiltered cubes are precomputed from the equirectangular image encoded
// in data.
ambient_load_environment :: proc(self: ^Renderer, data := DEFAULT_ENVIRONMENT) -> (ok: bool) {
  ambient_free_environment(self)
  defer if !ok do ambient_free_environment(self)
  self.environment_map = texture_create(self, data, .RGBA32F, true) or_return
  cube :: proc(size, mips: u32) -> TextureDesc {
    return {extent = {size, size}, format = .RGBA16F, usage = {.SAMPLED, .STORAGE}, mip_levels = mips, cube = true}
  }
  self.irradiance_cube = allocate_texture(self, cube(IRRADIANCE_SIZE, 1)) or_return
  self.prefilter_cube = allocate_texture(self, cube(PREFILTER_SIZE, PREFILTER_MIPS)) or_return
  return precompute_ibl(self, self.environment_map, self.irradiance_cube, self.prefilter_cube)
}

@(private = "file")
ambient_free_environment :: proc(self: ^Renderer) {
  texture_destroy(self, self.environment_map)
  texture_destroy(self, self.irradiance_cube)
  texture_destroy(self, self.prefilter_cube)
  self.environment_map, self.irradiance_cube, self.prefilter_cube = 0, 0, 0
}
