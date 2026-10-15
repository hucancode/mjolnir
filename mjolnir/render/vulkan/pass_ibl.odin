package vulkan_backend

import rhi "../rhi"

import "core:log"
import vk "vendor:vulkan"


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
PREFILTER_SAMPLES :: 1024
@(private = "file")
IRRADIANCE_SAMPLE_DELTA :: f32(0.025)

// dispatch i writes the cube level bound at PRECOMPUTE_STORAGE_BASE + i, after the depth pyramids' slots
@(private)
PRECOMPUTE_STORAGE_BASE :: MAX_PYRAMID_SLOTS * MAX_DEPTH_MIPS_LEVEL
@(private)
PRECOMPUTE_DISPATCHES :: 2 + rhi.PREFILTER_MIPS

// `src` is 2D for the equirect step, a cube otherwise; `value` is the irradiance sample delta or the prefilter roughness.
@(private = "file")
PrecomputePush :: struct {
  src:          u32,
  dst:          u32,
  face_size:    u32,
  value:        f32,
  sample_count: u32,
}

// precompute_ibl fills the cubes render made for image-based lighting, in one one-shot command
// buffer: equirect into env_cube, then irradiance and every prefilter mip (PREFILTER_MIPS) from it.
precompute_ibl :: proc(b: ^Backend, equirect, env_cube, irradiance_cube, prefilter_cube: rhi.TextureHandle) -> bool {
  return check(ibl_precompute(b, equirect, env_cube, irradiance_cube, prefilter_cube), "IBL precompute")
}

@(private = "file")
ibl_precompute :: proc(b: ^Backend, equirect, env_cube, irradiance_cube, prefilter_cube: rhi.TextureHandle) -> vk.Result {
  gctx := &b.gctx
  layout := b.scene.layout
  Dispatch :: struct {
    shader: PrecomputeShader,
    src:    rhi.TextureHandle,
    dst:    rhi.TextureHandle,
    mip:    u32,
    value:  f32,
    count:  u32,
  }
  dispatches: [PRECOMPUTE_DISPATCHES]Dispatch
  dispatches[0] = {.EQUIRECT, equirect, env_cube, 0, 0, 0}
  dispatches[1] = {.IRRADIANCE, env_cube, irradiance_cube, 0, IRRADIANCE_SAMPLE_DELTA, 0}
  for mip in 0 ..< u32(rhi.PREFILTER_MIPS) {
    roughness := f32(mip) / f32(rhi.PREFILTER_MIPS - 1)
    dispatches[2 + mip] = {.PREFILTER, env_cube, prefilter_cube, mip, roughness, PREFILTER_SAMPLES}
  }

  // image2DArray stores address the six faces of one mip level
  views: [PRECOMPUTE_DISPATCHES]vk.ImageView
  defer for v in views do vk.DestroyImageView(gctx.device, v, nil)
  for d, i in dispatches {
    views[i] = image_create_view(gctx.device, texture_image(b, d.dst), .D2_ARRAY, d.mip, 1, 0, 6) or_return
    write_descriptor(gctx, b.scene.bindless_set, BINDING_STORAGE_IMAGES, PRECOMPUTE_STORAGE_BASE + u32(i), .STORAGE_IMAGE, vk.DescriptorImageInfo{imageView = views[i], imageLayout = .GENERAL})
  }
  pipelines: [PrecomputeShader]vk.Pipeline
  defer for p in pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for &p, shader in pipelines do p = create_compute_pipeline(gctx, PRECOMPUTE_SHADERS[shader], layout) or_return

  cmd := begin_single_time_command(gctx) or_return
  vk.CmdBindDescriptorSets(cmd, .COMPUTE, layout, 1, 1, &b.scene.bindless_set, 0, nil)
  image_discard_barrier(
    cmd,
    {texture_image(b, env_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
    {texture_image(b, irradiance_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
    {texture_image(b, prefilter_cube).image, {.COLOR}, {.SHADER_WRITE}, {.COMPUTE_SHADER}},
  )
  for d, i in dispatches {
    size := max(texture_image(b, d.dst).extent.width >> d.mip, 1)
    push := PrecomputePush{u32(d.src), PRECOMPUTE_STORAGE_BASE + u32(i), size, d.value, d.count}
    vk.CmdBindPipeline(cmd, .COMPUTE, pipelines[d.shader])
    push_constants(b, cmd, &push)
    vk.CmdDispatch(cmd, (size + 7) / 8, (size + 7) / 8, 6)
    // later dispatches sample the env cube, the lighting passes the outputs
    memory_barrier(
      cmd,
      {.SHADER_WRITE}, {.SHADER_READ},
      {.COMPUTE_SHADER}, {.COMPUTE_SHADER, .FRAGMENT_SHADER},
    )
  }
  end_single_time_command(gctx, &cmd) or_return
  env, irr, pre := texture_image(b, env_cube), texture_image(b, irradiance_cube), texture_image(b, prefilter_cube)
  log.infof(
    "IBL precompute done: env=%d^2, irradiance=%d^2, prefilter=%d^2 x %d mips",
    env.extent.width, irr.extent.width, pre.extent.width, pre.mip_levels,
  )
  return .SUCCESS
}
