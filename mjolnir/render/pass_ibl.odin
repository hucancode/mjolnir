package render

import "core:log"
import "rhi"

@(private = "file")
PrecomputeShader :: enum {
  IRRADIANCE,
  PREFILTER,
}

@(private = "file")
PREFILTER_SAMPLES :: 1024
@(private = "file")
IRRADIANCE_SAMPLE_DELTA :: f32(0.025)

// dispatch i writes the cube level bound at PRECOMPUTE_STORAGE_BASE + i of the storage image
// array (Vulkan), after the depth pyramids' slots
@(private)
PRECOMPUTE_STORAGE_BASE :: MAX_PYRAMID_SLOTS * MAX_DEPTH_MIPS
@(private)
PRECOMPUTE_DISPATCHES :: 1 + PREFILTER_MIPS

// `src` is the equirect map; `value` is the irradiance sample delta
// or the prefilter roughness.
@(private = "file")
PrecomputePush :: struct {
  src:          u32,
  dst:          u32,
  face_size:    u32,
  value:        f32,
  sample_count: u32,
}

// precompute_ibl fills the cubes render made for image-based lighting from the mipped equirect
// map, in one submission: the irradiance and every prefilter mip (PREFILTER_MIPS).
// Each dispatch writes one cube level as six storage layers.
@(private)
precompute_ibl :: proc(self: ^Renderer, equirect, irradiance_cube, prefilter_cube: TextureHandle) -> bool {
  Dispatch :: struct {
    shader: PrecomputeShader,
    src:    TextureHandle,
    dst:    TextureHandle,
    // the face size of dst's level 0
    size:   u32,
    mip:    u32,
    value:  f32,
    count:  u32,
  }
  dispatches: [PRECOMPUTE_DISPATCHES]Dispatch
  dispatches[0] = {.IRRADIANCE, equirect, irradiance_cube, IRRADIANCE_SIZE, 0, IRRADIANCE_SAMPLE_DELTA, 0}
  for mip in 0 ..< u32(PREFILTER_MIPS) {
    roughness := f32(mip) / f32(PREFILTER_MIPS - 1)
    dispatches[1 + mip] = {.PREFILTER, equirect, prefilter_cube, PREFILTER_SIZE, mip, roughness, PREFILTER_SAMPLES}
  }
  sources := [PrecomputeShader]rhi.ShaderSource {
    .IRRADIANCE = shader_source("ibl_irradiance"),
    .PREFILTER  = shader_source("ibl_prefilter"),
  }
  when !BINDLESS do layouts: [PrecomputeShader]rhi.BindLayout
  pipelines: [PrecomputeShader]rhi.Pipeline
  groups: [PRECOMPUTE_DISPATCHES]rhi.BindGroup
  defer {
    for p in pipelines do dev.pipeline_retire(&self.gpu, p)
    for g in groups do dev.bind_group_retire(&self.gpu, g)
  }
  for shader in PrecomputeShader {
    layout := pipeline_layout(self, .NONE)
    when !BINDLESS {
      stages := bit_set[rhi.ShaderStage]{.COMPUTE}
      entries := [?]rhi.BindEntry{{kind = .TEXTURE_FLOAT, stages = stages}, {kind = .STORAGE_TEXTURE_ARRAY, stages = stages, format = .RGBA16F}}
      layouts[shader] = dev.bind_layout_create(&self.gpu, {entries = entries[:]}) or_return
      layout = pipeline_layout(self, .NONE, .NONE, layouts[shader])
    }
    pipelines[shader] = dev.compute_pipeline_create(&self.gpu, {sources[shader], layout}) or_return
  }
  when BINDLESS {
    for d, i in dispatches do dev.bindless_write(&self.gpu, .STORAGE_IMAGES, PRECOMPUTE_STORAGE_BASE + u32(i), rhi.TextureView{d.dst, i32(d.mip)})
  } else {
    for d, i in dispatches {
      resources := [2]rhi.BindResource{rhi.TextureView{d.src, -1}, rhi.TextureView{d.dst, i32(d.mip)}}
      groups[i] = dev.bind_group_create(&self.gpu, {layout = layouts[d.shader], resources = resources[:]}) or_return
    }
  }
  cmd := dev.cmd_begin(&self.gpu, .GRAPHICS, 0)
  // the equirect source may still be staged
  dev.cmd_flush_uploads(&self.gpu, cmd)
  dev.cmd_label_begin(&self.gpu, cmd, "ibl precompute")
  cubes := [2]TextureHandle{irradiance_cube, prefilter_cube}
  dev.cmd_barrier(&self.gpu, cmd, nil, cubes[:])
  dev.cmd_begin_compute(&self.gpu, cmd)
  for d, i in dispatches {
    size := max(d.size >> d.mip, 1)
    push := PrecomputePush{u32(d.src), PRECOMPUTE_STORAGE_BASE + u32(i), size, d.value, d.count}
    pipeline_bind(self, cmd, pipelines[d.shader], .NONE, 0, &push, .NONE)
    when !BINDLESS do dev.cmd_bind_group(&self.gpu, cmd, 3, groups[i])
    dev.cmd_dispatch(&self.gpu, cmd, (size + 7) / 8, (size + 7) / 8, 6)
    // the lighting passes sample the outputs
    written := [1]rhi.Barrier{{{.COMPUTE_SHADER}, {.COMPUTE_SHADER, .FRAGMENT_SHADER}, {.SHADER_WRITE}, {.SHADER_READ}}}
    dev.cmd_barrier(&self.gpu, cmd, written[:], nil)
  }
  dev.cmd_end_compute(&self.gpu, cmd)
  dev.cmd_label_end(&self.gpu, cmd)
  dev.cmd_end(&self.gpu, cmd)
  cmds := [1]rhi.CommandList{cmd}
  dev.submit(&self.gpu, {queue = .GRAPHICS, cmds = cmds[:]})
  dev.wait_idle(&self.gpu)
  log.infof(
    "IBL precompute done: irradiance=%d^2, prefilter=%d^2 x %d mips",
    IRRADIANCE_SIZE, PREFILTER_SIZE, PREFILTER_MIPS,
  )
  return true
}
