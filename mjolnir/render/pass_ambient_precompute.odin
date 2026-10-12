#+private
package render

import "gpu"
import "core:log"
import vk "vendor:vulkan"

PrecomputeShader :: enum {
  EQUIRECT,
  IRRADIANCE,
  PREFILTER,
}

PRECOMPUTE_SHADERS := [PrecomputeShader][]u8 {
  .EQUIRECT   = #load("shader/ibl/equirect_to_cube.spv"),
  .IRRADIANCE = #load("shader/ibl/irradiance.spv"),
  .PREFILTER  = #load("shader/ibl/prefilter.spv"),
}

ENV_CUBE_SIZE :: 512
IRRADIANCE_SIZE :: 32
PREFILTER_SIZE :: 128
PREFILTER_MIPS :: 5
PREFILTER_SAMPLES :: 1024
IRRADIANCE_SAMPLE_DELTA :: f32(0.025)
CUBE_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

// Storage-image slots of the precompute targets, after the depth pyramids':
// dispatch i writes the cube level bound at PRECOMPUTE_STORAGE_BASE + i.
PRECOMPUTE_STORAGE_BASE :: MAX_PYRAMID_SLOTS * MAX_DEPTH_MIPS_LEVEL
PRECOMPUTE_DISPATCHES :: 2 + PREFILTER_MIPS

// Push constants of the precompute shaders: read texture `src` (2D for the
// equirect step, a cube otherwise), write all six faces of storage image
// `dst`. `value` is the irradiance sample delta or the prefilter roughness.
PrecomputePush :: struct {
  src:          u32,
  dst:          u32,
  face_size:    u32,
  value:        f32,
  sample_count: u32,
}

// Outputs from a single ambient_precompute run. The caller owns the handles and must
// free them via ambient_free_results.
IBLResults :: struct {
  irradiance_cube: TextureHandle,
  prefilter_cube:  TextureHandle,
}

// Precompute IBL cubemaps from an equirectangular HDR source texture in one
// one-shot command buffer: equirect to an intermediate env cube (freed before
// returning), then irradiance and every prefilter mip from it. The shaders
// run on the scene layout, reading the bindless textures and writing the
// precompute storage-image slots.
ambient_precompute :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  layout: vk.PipelineLayout,
  equirect: TextureHandle,
) -> (
  results: IBLResults,
  ret: vk.Result,
) {
  env_cube := allocate_texture(
    texture_manager,
    gctx,
    {ENV_CUBE_SIZE, ENV_CUBE_SIZE},
    CUBE_FORMAT,
    {.SAMPLED, .STORAGE},
    cube = true,
  ) or_return
  defer free_texture(texture_manager, gctx, env_cube)
  results.irradiance_cube = allocate_texture(
    texture_manager,
    gctx,
    {IRRADIANCE_SIZE, IRRADIANCE_SIZE},
    CUBE_FORMAT,
    {.SAMPLED, .STORAGE},
    cube = true,
  ) or_return
  results.prefilter_cube = allocate_texture(
    texture_manager,
    gctx,
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
  dispatches[1] = {.IRRADIANCE, env_cube, results.irradiance_cube, 0, IRRADIANCE_SAMPLE_DELTA, 0}
  for mip in 0 ..< u32(PREFILTER_MIPS) {
    roughness := f32(mip) / f32(PREFILTER_MIPS - 1)
    dispatches[2 + mip] = {.PREFILTER, env_cube, results.prefilter_cube, mip, roughness, PREFILTER_SAMPLES}
  }

  // image2DArray stores address the six faces of one mip level
  views: [PRECOMPUTE_DISPATCHES]vk.ImageView
  defer for v in views do vk.DestroyImageView(gctx.device, v, nil)
  for d, i in dispatches {
    views[i] = gpu.image_create_view(gctx.device, get_texture(texture_manager, d.dst), .D2_ARRAY, d.mip, 1, 0, 6) or_return
    gpu.write_descriptor(gctx, texture_manager.descriptor_set, BINDING_STORAGE_IMAGES, PRECOMPUTE_STORAGE_BASE + u32(i), .STORAGE_IMAGE, vk.DescriptorImageInfo{imageView = views[i], imageLayout = .GENERAL})
  }
  pipelines: [PrecomputeShader]vk.Pipeline
  defer for p in pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for &p, shader in pipelines do p = gpu.create_compute_pipeline(gctx, PRECOMPUTE_SHADERS[shader], layout) or_return

  cmd := gpu.begin_single_time_command(gctx) or_return
  vk.CmdBindDescriptorSets(cmd, .COMPUTE, layout, 1, 1, &texture_manager.descriptor_set, 0, nil)
  // The cubes were just allocated; move out of UNDEFINED for storage write.
  gpu.image_discard_barrier(
    cmd,
    {get_texture(texture_manager, env_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
    {get_texture(texture_manager, results.irradiance_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
    {get_texture(texture_manager, results.prefilter_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
  )
  for d, i in dispatches {
    size := max(get_texture(texture_manager, d.dst).extent.width >> d.mip, 1)
    push := PrecomputePush{texture_index(d.src), PRECOMPUTE_STORAGE_BASE + u32(i), size, d.value, d.count}
    vk.CmdBindPipeline(cmd, .COMPUTE, pipelines[d.shader])
    push_layout_constants(cmd, layout, &push)
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
  return results, .SUCCESS
}

ambient_free_results :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  r: ^IBLResults,
) {
  free_texture(texture_manager, gctx, r.irradiance_cube)
  free_texture(texture_manager, gctx, r.prefilter_cube)
  r^ = {}
}
