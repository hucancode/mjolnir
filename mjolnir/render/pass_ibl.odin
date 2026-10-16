package render

import "core:log"
import "rhi"

@(private = "file")
PrecomputeShader :: enum {
  EQUIRECT,
  IRRADIANCE,
  PREFILTER,
}

@(private = "file")
PREFILTER_SAMPLES :: 1024
@(private = "file")
IRRADIANCE_SAMPLE_DELTA :: f32(0.025)

// dispatch i writes the cube level bound at PRECOMPUTE_STORAGE_BASE + i of the storage image
// array (Vulkan), after the depth pyramids' slots
@(private = "file")
PRECOMPUTE_STORAGE_BASE :: MAX_PYRAMID_SLOTS * MAX_DEPTH_MIPS
@(private = "file")
PRECOMPUTE_DISPATCHES :: 2 + PREFILTER_MIPS

// `src` is 2D for the equirect step, a cube otherwise; `value` is the irradiance sample delta
// or the prefilter roughness.
@(private = "file")
PrecomputePush :: struct {
  src:          u32,
  dst:          u32,
  face_size:    u32,
  value:        f32,
  sample_count: u32,
}

// precompute_ibl fills the cubes render made for image-based lighting, in one submission:
// equirect into env_cube, then irradiance and every prefilter mip (PREFILTER_MIPS) from it.
// Each dispatch writes one cube level as six storage layers.
@(private)
precompute_ibl :: proc(r: ^Renderer, equirect, env_cube, irradiance_cube, prefilter_cube: TextureHandle) -> bool {
  caps := r.res.caps
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
  common := wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/ibl_common.wgsl"))
  spirvs := [PrecomputeShader][]u8 {
    .EQUIRECT   = spirv("shader/vulkan/ibl/equirect_to_cube.spv"),
    .IRRADIANCE = spirv("shader/vulkan/ibl/irradiance.spv"),
    .PREFILTER  = spirv("shader/vulkan/ibl/prefilter.spv"),
  }
  wgsls := [PrecomputeShader]string {
    .EQUIRECT   = wgsl_join(common, wgsl("shader/wgpu/ibl_equirect.wgsl")),
    .IRRADIANCE = wgsl_join(common, wgsl("shader/wgpu/ibl_irradiance.wgsl")),
    .PREFILTER  = wgsl_join(common, wgsl("shader/wgpu/ibl_prefilter.wgsl")),
  }
  layouts: [PrecomputeShader]rhi.BindLayout
  pipelines: [PrecomputeShader]rhi.Pipeline
  groups: [PRECOMPUTE_DISPATCHES]rhi.BindGroup
  defer {
    for p in pipelines do dev.pipeline_retire(&r.gpu, p)
    for g in groups do dev.bind_group_retire(&r.gpu, g)
  }
  for shader in PrecomputeShader {
    layout := pipeline_layout(r, .NONE)
    if !caps.bindless {
      stages := bit_set[rhi.ShaderStage]{.COMPUTE}
      entries := [?]rhi.BindEntry{{kind = .TEXTURE_FLOAT if shader == .EQUIRECT else .TEXTURE_CUBE, stages = stages}, {kind = .STORAGE_TEXTURE_ARRAY, stages = stages, format = .RGBA16F}}
      layouts[shader] = dev.bind_layout_create(&r.gpu, {entries = entries[:]}) or_return
      layout = pipeline_layout(r, .NONE, .NONE, layouts[shader])
    }
    pipelines[shader] = dev.compute_pipeline_create(&r.gpu, {{spirv = {comp = spirvs[shader]}, wgsl = wgsls[shader]}, layout}) or_return
  }
  if caps.bindless {
    for d, i in dispatches do dev.bindless_write(&r.gpu, .STORAGE_IMAGES, PRECOMPUTE_STORAGE_BASE + u32(i), rhi.TextureView{d.dst, i32(d.mip)})
  } else {
    for d, i in dispatches {
      resources := [2]rhi.BindResource{rhi.TextureView{d.src, -1}, rhi.TextureView{d.dst, i32(d.mip)}}
      groups[i] = dev.bind_group_create(&r.gpu, {layout = layouts[d.shader], resources = resources[:]}) or_return
    }
  }
  cmd := dev.cmd_begin(&r.gpu, .GRAPHICS, 0)
  // the equirect source may still be staged
  dev.cmd_flush_uploads(&r.gpu, cmd)
  dev.cmd_label_begin(&r.gpu, cmd, "ibl precompute")
  cubes := [3]TextureHandle{env_cube, irradiance_cube, prefilter_cube}
  dev.cmd_barrier(&r.gpu, cmd, nil, cubes[:])
  dev.cmd_begin_compute(&r.gpu, cmd)
  for d, i in dispatches {
    size := max(r.texture_descs[d.dst].extent.x >> d.mip, 1)
    push := PrecomputePush{u32(d.src), PRECOMPUTE_STORAGE_BASE + u32(i), size, d.value, d.count}
    pipeline_bind(r, cmd, pipelines[d.shader], .NONE, 0, &push, .NONE)
    if !caps.bindless do dev.cmd_bind_group(&r.gpu, cmd, 3, groups[i])
    dev.cmd_dispatch(&r.gpu, cmd, (size + 7) / 8, (size + 7) / 8, 6)
    // later dispatches sample the env cube, the lighting passes the outputs
    written := [1]rhi.Barrier{{{.COMPUTE_SHADER}, {.COMPUTE_SHADER, .FRAGMENT_SHADER}, {.SHADER_WRITE}, {.SHADER_READ}}}
    dev.cmd_barrier(&r.gpu, cmd, written[:], nil)
  }
  dev.cmd_end_compute(&r.gpu, cmd)
  dev.cmd_label_end(&r.gpu, cmd)
  dev.cmd_end(&r.gpu, cmd)
  cmds := [1]rhi.CommandList{cmd}
  dev.submit(&r.gpu, {queue = .GRAPHICS, cmds = cmds[:]})
  dev.wait_idle(&r.gpu)
  log.infof(
    "IBL precompute done: env=%d^2, irradiance=%d^2, prefilter=%d^2 x %d mips",
    r.texture_descs[env_cube].extent.x, r.texture_descs[irradiance_cube].extent.x, r.texture_descs[prefilter_cube].extent.x, PREFILTER_MIPS,
  )
  return true
}
