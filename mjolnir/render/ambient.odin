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

// An equirectangular environment image and the image-based lighting cubes precomputed from it.
Environment :: struct {
  image, irradiance, prefilter: TextureHandle,
}

ambient_init :: proc(self: ^Renderer) -> bool {
  self.brdf_lut = texture_create(self, TEXTURE_LUT_GGX) or_return
  self.default_environment = ambient_load(self, DEFAULT_ENVIRONMENT) or_return
  ambient_reset(self)
  return true
}

// Back to init's settings and default environment; teardown frees a loaded one's textures.
ambient_reset :: proc(self: ^Renderer) {
  self.ibl_intensity = 1.0
  self.skybox_intensity = 1.0
  self.skybox_blur = 0.25
  self.environment = self.default_environment
}

// The environment of the equirectangular image encoded in data, its cubes precomputed.
ambient_load :: proc(self: ^Renderer, data: []u8) -> (env: Environment, ok: bool) {
  defer if !ok do ambient_free(self, env)
  env.image = texture_create(self, data, .RGBA32F, true) or_return
  cube :: proc(size, mips: u32) -> TextureDesc {
    return {extent = {size, size}, format = .RGBA16F, usage = {.SAMPLED, .STORAGE}, mip_levels = mips, cube = true}
  }
  env.irradiance = allocate_texture(self, cube(IRRADIANCE_SIZE, 1)) or_return
  env.prefilter = allocate_texture(self, cube(PREFILTER_SIZE, PREFILTER_MIPS)) or_return
  ok = precompute_ibl(self, env.image, env.irradiance, env.prefilter)
  return
}

ambient_free :: proc(self: ^Renderer, env: Environment) {
  texture_destroy(self, env.image)
  texture_destroy(self, env.irradiance)
  texture_destroy(self, env.prefilter)
}
