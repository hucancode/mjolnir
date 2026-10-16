#+private
package render

@(private = "file")
TEXTURE_LUT_GGX :: #load("assets/lut_ggx.png")

// face sizes of the image-based lighting cubes (pass_ibl.odin)
ENV_CUBE_SIZE :: 512
IRRADIANCE_SIZE :: 32
PREFILTER_SIZE :: 128

ambient_init :: proc(r: ^Renderer) -> bool {
  r.brdf_lut = texture_load(r, TEXTURE_LUT_GGX) or_return
  r.ibl_intensity = 1.0
  r.skybox_intensity = 1.0
  r.skybox_blur = 0.25
  return true
}

// The irradiance and prefiltered cubes are precomputed from a temporary env cube made from
// the equirectangular image encoded in data.
ambient_load_environment :: proc(r: ^Renderer, data: []u8) -> (ok: bool) {
  ambient_free_environment(r)
  defer if !ok do ambient_free_environment(r)
  r.environment_map = texture_load(r, data, .RGBA32F, true) or_return
  cube :: proc(size, mips: u32) -> TextureDesc {
    return {extent = {size, size}, format = .RGBA16F, usage = {.SAMPLED, .STORAGE}, mip_levels = mips, cube = true}
  }
  env_cube := allocate_texture(r, cube(ENV_CUBE_SIZE, 1)) or_return
  defer texture_destroy(r, env_cube)
  r.irradiance_cube = allocate_texture(r, cube(IRRADIANCE_SIZE, 1)) or_return
  r.prefilter_cube = allocate_texture(r, cube(PREFILTER_SIZE, PREFILTER_MIPS)) or_return
  return precompute_ibl(r, r.environment_map, env_cube, r.irradiance_cube, r.prefilter_cube)
}

@(private = "file")
ambient_free_environment :: proc(r: ^Renderer) {
  texture_destroy(r, r.environment_map)
  texture_destroy(r, r.irradiance_cube)
  texture_destroy(r, r.prefilter_cube)
  r.environment_map, r.irradiance_cube, r.prefilter_cube = 0, 0, 0
}
