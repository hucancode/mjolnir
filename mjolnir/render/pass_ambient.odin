#+private
package render

import "core:log"
import "gpu"
import vk "vendor:vulkan"

@(private = "file")
TEXTURE_LUT_GGX :: #load("assets/lut_ggx.png")

ambient_init :: proc(r: ^Renderer) -> vk.Result {
  r.brdf_lut = create_texture_from_data(r, TEXTURE_LUT_GGX) or_return
  r.ibl_intensity = 1.0
  r.skybox_intensity = 1.0
  r.skybox_blur = 0.25
  return .SUCCESS
}

ambient_load_environment :: proc(r: ^Renderer, path: string) -> (ret: vk.Result) {
  ambient_free_environment(r)
  defer if ret != .SUCCESS do ambient_free_environment(r)
  r.environment_map = create_texture_from_path(r, path, .R32G32B32A32_SFLOAT, true) or_return
  r.irradiance_cube, r.prefilter_cube = ambient_precompute(r, r.environment_map) or_return
  return .SUCCESS
}

@(private = "file")
ambient_free_environment :: proc(r: ^Renderer) {
  destroy_texture(r, r.environment_map)
  destroy_texture(r, r.irradiance_cube)
  destroy_texture(r, r.prefilter_cube)
  r.environment_map, r.irradiance_cube, r.prefilter_cube = 0, 0, 0
}

@(private = "file")
PrecomputeShader :: enum {
  EQUIRECT,
  IRRADIANCE,
  PREFILTER,
}

@(private = "file")
PRECOMPUTE_SHADERS := [PrecomputeShader][]u8 {
  .EQUIRECT   = #load("shader/ibl/equirect_to_cube.spv"),
  .IRRADIANCE = #load("shader/ibl/irradiance.spv"),
  .PREFILTER  = #load("shader/ibl/prefilter.spv"),
}

@(private = "file")
ENV_CUBE_SIZE :: 512
@(private = "file")
IRRADIANCE_SIZE :: 32
@(private = "file")
PREFILTER_SIZE :: 128
@(private = "file")
PREFILTER_MIPS :: 5
@(private = "file")
PREFILTER_SAMPLES :: 1024
@(private = "file")
IRRADIANCE_SAMPLE_DELTA :: f32(0.025)
@(private = "file")
CUBE_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

// dispatch i writes the cube level bound at PRECOMPUTE_STORAGE_BASE + i, after the depth pyramids' slots
PRECOMPUTE_STORAGE_BASE :: MAX_PYRAMID_SLOTS * MAX_DEPTH_MIPS_LEVEL
PRECOMPUTE_DISPATCHES :: 2 + PREFILTER_MIPS

// `src` is 2D for the equirect step, a cube otherwise; `value` is the irradiance sample delta or the prefilter roughness.
@(private = "file")
PrecomputePush :: struct {
  src:          u32,
  dst:          u32,
  face_size:    u32,
  value:        f32,
  sample_count: u32,
}

// One one-shot command buffer: equirect to a temporary env cube, then irradiance and every
// prefilter mip from it. The caller owns the two output cubes.
@(private = "file")
ambient_precompute :: proc(
  r: ^Renderer,
  equirect: TextureHandle,
) -> (
  irradiance_cube, prefilter_cube: TextureHandle,
  ret: vk.Result,
) {
  gctx := &r.gctx
  layout := r.scene.layout
  defer if ret != .SUCCESS {
    destroy_texture(r, irradiance_cube)
    destroy_texture(r, prefilter_cube)
  }
  env_cube := allocate_texture(
    r,
    {ENV_CUBE_SIZE, ENV_CUBE_SIZE},
    CUBE_FORMAT,
    {.SAMPLED, .STORAGE},
    cube = true,
  ) or_return
  defer destroy_texture(r, env_cube)
  irradiance_cube = allocate_texture(
    r,
    {IRRADIANCE_SIZE, IRRADIANCE_SIZE},
    CUBE_FORMAT,
    {.SAMPLED, .STORAGE},
    cube = true,
  ) or_return
  prefilter_cube = allocate_texture(
    r,
    {PREFILTER_SIZE, PREFILTER_SIZE},
    CUBE_FORMAT,
    {.SAMPLED, .STORAGE},
    PREFILTER_MIPS,
    cube = true,
  ) or_return

  Dispatch :: struct {
    shader: PrecomputeShader,
    src:    TextureHandle,
    dst:    TextureHandle,
    mip:    u32,
    value:  f32,
    count:  u32,
  }
  dispatches: [PRECOMPUTE_DISPATCHES]Dispatch
  dispatches[0] = {.EQUIRECT, equirect, env_cube, 0, 0, 0}
  dispatches[1] = {.IRRADIANCE, env_cube, irradiance_cube, 0, IRRADIANCE_SAMPLE_DELTA, 0}
  for mip in 0 ..< u32(PREFILTER_MIPS) {
    roughness := f32(mip) / f32(PREFILTER_MIPS - 1)
    dispatches[2 + mip] = {.PREFILTER, env_cube, prefilter_cube, mip, roughness, PREFILTER_SAMPLES}
  }

  // image2DArray stores address the six faces of one mip level
  views: [PRECOMPUTE_DISPATCHES]vk.ImageView
  defer for v in views do vk.DestroyImageView(gctx.device, v, nil)
  for d, i in dispatches {
    views[i] = gpu.image_create_view(gctx.device, texture_image(r, d.dst), .D2_ARRAY, d.mip, 1, 0, 6) or_return
    gpu.write_descriptor(gctx, r.scene.bindless_set, BINDING_STORAGE_IMAGES, PRECOMPUTE_STORAGE_BASE + u32(i), .STORAGE_IMAGE, vk.DescriptorImageInfo{imageView = views[i], imageLayout = .GENERAL})
  }
  pipelines: [PrecomputeShader]vk.Pipeline
  defer for p in pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for &p, shader in pipelines do p = gpu.create_compute_pipeline(gctx, PRECOMPUTE_SHADERS[shader], layout) or_return

  cmd := gpu.begin_single_time_command(gctx) or_return
  vk.CmdBindDescriptorSets(cmd, .COMPUTE, layout, 1, 1, &r.scene.bindless_set, 0, nil)
  gpu.image_discard_barrier(
    cmd,
    {texture_image(r, env_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
    {texture_image(r, irradiance_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
    {texture_image(r, prefilter_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
  )
  for d, i in dispatches {
    size := max(texture_image(r, d.dst).extent.width >> d.mip, 1)
    push := PrecomputePush{u32(d.src), PRECOMPUTE_STORAGE_BASE + u32(i), size, d.value, d.count}
    vk.CmdBindPipeline(cmd, .COMPUTE, pipelines[d.shader])
    push_constants(r, cmd, &push)
    vk.CmdDispatch(cmd, (size + 7) / 8, (size + 7) / 8, 6)
    // later dispatches sample the env cube, the lighting passes the outputs
    gpu.memory_barrier(
      cmd,
      {.SHADER_WRITE}, {.SHADER_READ},
      {.COMPUTE_SHADER}, {.COMPUTE_SHADER, .FRAGMENT_SHADER},
    )
  }
  gpu.end_single_time_command(gctx, &cmd) or_return
  log.infof(
    "IBL precompute done: env=%d^2, irradiance=%d^2, prefilter=%d^2 x %d mips",
    ENV_CUBE_SIZE, IRRADIANCE_SIZE, PREFILTER_SIZE, PREFILTER_MIPS,
  )
  return irradiance_cube, prefilter_cube, .SUCCESS
}
