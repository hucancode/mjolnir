package render

import "rhi"

// Particles live in a ring buffer of MAX_PARTICLES slots (oldest overwritten when full).
// Emit spawns each emitter's share at its ring cursor; simulate advances live slots in place
// and appends them to the alive list, whose header is the indirect draw: one point per alive
// particle (Vulkan), or a camera-facing quad of six vertices instanced per alive particle
// (WebGPU points are one pixel).
@(private = "file")
COMPUTE_PARTICLE_BATCH :: 256
#assert(MAX_PARTICLES % COMPUTE_PARTICLE_BATCH == 0)

// a slot is dead when life <= 0
@(private)
Particle :: struct {
  position:      [3]f32,
  size_start:    f32,
  velocity:      [3]f32,
  size_end:      f32,
  color_start:   [4]f32,
  color_end:     [4]f32,
  life:          f32,
  max_life:      f32,
  weight:        f32,
  texture_index: u32,
}

// The alive list's indirect draw: vertex count, instance count, first vertex, first instance.
@(private)
PARTICLE_ALIVE_HEADER :: 4

// distinct textures the particle pass draws with (WebGPU)
@(private = "file")
MAX_PARTICLE_TEXTURES :: 8

@(private)
ParticleState :: struct {
  emit, simulate, draw: rhi.Pipeline,
}

@(private = "file")
ParticleDrawPush :: struct {
  camera_index: u32,
  _:            [3]u32,
  // the texture handle each slot of the particle texture group holds
  textures:     [MAX_PARTICLE_TEXTURES]u32,
}

@(private)
particles_init :: proc(r: ^Renderer) -> bool {
  common := wgsl("shader/wgpu/common.wgsl")
  bindless := r.res.caps.bindless
  r.particle_gpu.emit = dev.compute_pipeline_create(
    &r.gpu,
    {{spirv = {comp = spirv("shader/vulkan/particle/emitter.spv")}, wgsl = wgsl_join(common, wgsl("shader/wgpu/particle_emit.wgsl"))}, pipeline_layout(r, .PARTICLE_EMIT)},
  ) or_return
  r.particle_gpu.simulate = dev.compute_pipeline_create(
    &r.gpu,
    {{spirv = {comp = spirv("shader/vulkan/particle/compute.spv")}, wgsl = wgsl_join(common, wgsl("shader/wgpu/particle_simulate.wgsl"))}, pipeline_layout(r, .PARTICLE_SIMULATE)},
  ) or_return
  r.particle_gpu.draw = dev.graphics_pipeline_create(
    &r.gpu,
    {
      shader = {
        spirv = {vert = spirv("shader/vulkan/particle/vert.spv"), frag = spirv("shader/vulkan/particle/frag.spv")},
        wgsl = wgsl_join(common, wgsl("shader/wgpu/particle.wgsl")),
      },
      layout = pipeline_layout(r, .PARTICLE_DRAW, .PARTICLES),
      topology = .POINT_LIST if bindless else .TRIANGLE_LIST,
      // drawn in the forward pass
      color_formats = material_pass_formats(.FORWARD),
      blend = .ALPHA,
      depth = material_pass_depth(.FORWARD),
    },
  ) or_return
  return particles_gpu_reset(r)
}

// Kills every particle before the next frame.
@(private)
particles_gpu_reset :: proc(r: ^Renderer) -> bool {
  dev.buffer_write(&r.gpu, r.res.particles, 0, make([]u8, MAX_PARTICLES * size_of(Particle), context.temp_allocator)) or_return
  header := [PARTICLE_ALIVE_HEADER]u32{0, 1, 0, 0} if r.res.caps.bindless else {6, 0, 0, 0}
  return dev.buffer_write(&r.gpu, r.res.particle_alive, 0, ([^]u8)(&header)[:size_of(header)])
}

// After drawing: the next frame draws what this simulates.
@(private)
particles_simulate :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32) {
  params := &r.particle_params
  // the previous simulation and this frame's draws use what gets rewritten
  barrier(r, cmd, .PARTICLES_TO_FILL)
  // the alive count: the vertex count for points, the instance count for quads
  count_word := 0 if r.res.caps.bindless else size_of(u32)
  dev.cmd_fill_buffer(&r.gpu, cmd, r.res.particle_alive, count_word, size_of(u32))
  dev.cmd_begin_compute(&r.gpu, cmd)
  defer dev.cmd_end_compute(&r.gpu, cmd)
  if params.emit_total > 0 {
    pipeline_bind(r, cmd, r.particle_gpu.emit, .PARTICLE_EMIT, f, params, .NONE)
    dev.cmd_dispatch(&r.gpu, cmd, (params.emit_total + 63) / 64, 1, 1)
  }
  barrier(r, cmd, .FILL_TO_COMPUTE)
  pipeline_bind(r, cmd, r.particle_gpu.simulate, .PARTICLE_SIMULATE, f, params, .NONE)
  dev.cmd_dispatch(&r.gpu, cmd, MAX_PARTICLES / COMPUTE_PARTICLE_BATCH, 1, 1)
}

// Inside the forward pass. Where textures are bound as groups (WebGPU) particles sample the
// first MAX_PARTICLE_TEXTURES distinct emitter textures; the rest draw untextured.
@(private)
particles_draw :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32, camera_index: u32) {
  push := ParticleDrawPush{camera_index = camera_index}
  textures: [MAX_PARTICLE_TEXTURES]TextureHandle
  if !r.res.caps.bindless {
    n := 0
    emitters := write_table(r, .EMITTERS, Emitter)[:r.particle_params.emitter_count]
    outer: for &em in emitters {
      if em.texture_index == 0 || n == MAX_PARTICLE_TEXTURES do continue
      for t in textures[:n] do if t == em.texture_index do continue outer
      textures[n] = em.texture_index
      push.textures[n] = u32(em.texture_index)
      n += 1
    }
  }
  pipeline_bind(r, cmd, r.particle_gpu.draw, .PARTICLE_DRAW, f, &push, .PARTICLES, ..textures[:])
  dev.cmd_draw_indirect(&r.gpu, cmd, r.res.particle_alive, 0, 1, 0)
}
