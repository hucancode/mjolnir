package wgpu_backend

import rhi "../rhi"

import "core:log"
import wgpu "vendor:wgpu"


@(private = "file")
PrecomputeShader :: enum {
  EQUIRECT,
  IRRADIANCE,
  PREFILTER,
}

@(private = "file")
IBL_COMMON :: #load("shader/common.wgsl", string) + #load("shader/ibl_common.wgsl", string)

@(private = "file")
PRECOMPUTE_SHADERS := [PrecomputeShader]string {
  .EQUIRECT   = IBL_COMMON + #load("shader/ibl_equirect.wgsl", string),
  .IRRADIANCE = IBL_COMMON + #load("shader/ibl_irradiance.wgsl", string),
  .PREFILTER  = IBL_COMMON + #load("shader/ibl_prefilter.wgsl", string),
}

@(private = "file")
PREFILTER_SAMPLES :: 1024
@(private = "file")
IRRADIANCE_SAMPLE_DELTA :: f32(0.025)
@(private = "file")
PRECOMPUTE_DISPATCHES :: 2 + rhi.PREFILTER_MIPS

// `value` is the irradiance sample delta or the prefilter roughness.
@(private = "file")
PrecomputeUniforms :: struct {
  face_size:    u32,
  value:        f32,
  sample_count: u32,
}

// precompute_ibl fills the cubes render made for image-based lighting in one submission:
// equirect into env_cube, then irradiance and every prefilter mip (PREFILTER_MIPS) from it.
// Each dispatch binds its source (group 3 binding 0: 2D for the equirect step, a cube
// otherwise) and one cube level as six storage layers (binding 1).
precompute_ibl :: proc(b: ^Backend, equirect, env_cube, irradiance_cube, prefilter_cube: rhi.TextureHandle) -> bool {
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
  layouts: [PrecomputeShader]wgpu.BindGroupLayout
  pipelines: [PrecomputeShader]wgpu.ComputePipeline
  defer for shader in PrecomputeShader {
    wgpu.ComputePipelineRelease(pipelines[shader])
    wgpu.BindGroupLayoutRelease(layouts[shader])
  }
  for shader in PrecomputeShader {
    entries := [?]wgpu.BindGroupLayoutEntry {
      {binding = 0, visibility = {.Compute}, texture = {sampleType = .Float, viewDimension = ._2D if shader == .EQUIRECT else .Cube}},
      {binding = 1, visibility = {.Compute}, storageTexture = {access = .WriteOnly, format = .RGBA16Float, viewDimension = ._2DArray}},
    }
    layouts[shader] = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(entries), entries = raw_data(entries[:])})
    pipelines[shader] = compute_pipeline(b, PRECOMPUTE_SHADERS[shader], .NONE, .NONE, layouts[shader])
  }
  encoder := wgpu.DeviceCreateCommandEncoder(b.device)
  pass := wgpu.CommandEncoderBeginComputePass(encoder)
  views: [PRECOMPUTE_DISPATCHES]wgpu.TextureView
  groups: [PRECOMPUTE_DISPATCHES]wgpu.BindGroup
  wgpu.ComputePassEncoderSetBindGroup(pass, 0, b.scene_groups[.NONE])
  wgpu.ComputePassEncoderSetBindGroup(pass, 1, group(b, {layout = .NONE}))
  for d, i in dispatches {
    dst := &b.textures[d.dst]
    views[i] = wgpu.TextureCreateView(dst.texture, &{dimension = ._2DArray, baseMipLevel = d.mip, mipLevelCount = 1, arrayLayerCount = 6})
    entries := [?]wgpu.BindGroupEntry{{binding = 0, textureView = b.textures[d.src].view}, {binding = 1, textureView = views[i]}}
    groups[i] = wgpu.DeviceCreateBindGroup(b.device, &{layout = layouts[d.shader], entryCount = len(entries), entries = raw_data(entries[:])})
    size := max(dst.desc.extent.x >> d.mip, 1)
    u := PrecomputeUniforms{size, d.value, d.count}
    offset := uniform(b, &u)
    wgpu.ComputePassEncoderSetPipeline(pass, pipelines[d.shader])
    wgpu.ComputePassEncoderSetBindGroup(pass, 2, b.frame_group, {offset})
    wgpu.ComputePassEncoderSetBindGroup(pass, 3, groups[i])
    wgpu.ComputePassEncoderDispatchWorkgroups(pass, (size + 7) / 8, (size + 7) / 8, 6)
  }
  wgpu.ComputePassEncoderEnd(pass)
  wgpu.ComputePassEncoderRelease(pass)
  commands := wgpu.CommandEncoderFinish(encoder)
  uniforms_flush(b)
  wgpu.QueueSubmit(b.queue, {commands})
  wgpu.CommandBufferRelease(commands)
  wgpu.CommandEncoderRelease(encoder)
  for g in groups do wgpu.BindGroupRelease(g)
  for v in views do wgpu.TextureViewRelease(v)
  env, irr, pre := &b.textures[env_cube], &b.textures[irradiance_cube], &b.textures[prefilter_cube]
  log.infof(
    "IBL precompute done: env=%d^2, irradiance=%d^2, prefilter=%d^2 x %d mips",
    env.desc.extent.x, irr.desc.extent.x, pre.desc.extent.x, pre.desc.mip_levels,
  )
  return true
}
