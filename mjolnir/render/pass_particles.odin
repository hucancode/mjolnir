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
  drag:          f32,
  _pad:          [3]f32,
}

// The alive list's indirect draw: vertex count, instance count, first vertex, first instance.
@(private)
PARTICLE_ALIVE_HEADER :: 4

// distinct textures the particle pass draws with (WebGPU)
@(private = "file")
MAX_PARTICLE_TEXTURES :: 8

@(private = "file")
ParticleDrawPush :: struct {
  camera_index: u32,
  _:            [3]u32,
  // the texture handle each slot of the particle texture group holds
  textures:     [MAX_PARTICLE_TEXTURES]u32,
}

@(private)
particles_init :: proc(self: ^Renderer) -> bool {
  self.particle_emit_pipeline = dev.compute_pipeline_create(
    &self.gpu,
    {shader_source("particle_emit"), pipeline_layout(self, .PARTICLE_EMIT)},
  ) or_return
  self.particle_sim_pipeline = dev.compute_pipeline_create(
    &self.gpu,
    {shader_source("particle_simulate"), pipeline_layout(self, .PARTICLE_SIMULATE)},
  ) or_return
  self.particle_draw_pipeline = dev.graphics_pipeline_create(
    &self.gpu,
    {
      shader = shader_source("particle"),
      layout = pipeline_layout(self, .PARTICLE_DRAW, .PARTICLES),
      topology = .POINT_LIST if BINDLESS else .TRIANGLE_LIST,
      // drawn in the forward pass
      color_formats = material_pass_formats(.FORWARD),
      blend = .ALPHA,
      depth = material_pass_depth(.FORWARD),
    },
  ) or_return
  return particles_gpu_reset(self)
}

// Kills every particle before the next frame.
@(private)
particles_gpu_reset :: proc(self: ^Renderer) -> bool {
  dev.buffer_write(&self.gpu, self.buffers[.PARTICLES][0], 0, make([]u8, MAX_PARTICLES * size_of(Particle), context.temp_allocator)) or_return
  header := [PARTICLE_ALIVE_HEADER]u32{0, 1, 0, 0} if BINDLESS else {6, 0, 0, 0}
  return dev.buffer_write(&self.gpu, self.buffers[.PARTICLE_ALIVE][0], 0, ([^]u8)(&header)[:size_of(header)])
}

// After drawing: the next frame draws what this simulates.
@(private)
particles_simulate :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  params := &self.particle_params
  // the previous simulation and this frame's draws use what gets rewritten
  barrier(self, cmd, .PARTICLES_TO_FILL)
  // the alive count: the vertex count for points, the instance count for quads
  count_word := 0 if BINDLESS else size_of(u32)
  dev.cmd_fill_buffer(&self.gpu, cmd, self.buffers[.PARTICLE_ALIVE][0], count_word, size_of(u32))
  dev.cmd_begin_compute(&self.gpu, cmd)
  defer dev.cmd_end_compute(&self.gpu, cmd)
  if params.emit_total > 0 {
    pipeline_bind(self, cmd, self.particle_emit_pipeline, .PARTICLE_EMIT, f, params, .NONE)
    dev.cmd_dispatch(&self.gpu, cmd, (params.emit_total + 63) / 64, 1, 1)
  }
  barrier(self, cmd, .FILL_TO_COMPUTE)
  pipeline_bind(self, cmd, self.particle_sim_pipeline, .PARTICLE_SIMULATE, f, params, .NONE)
  dev.cmd_dispatch(&self.gpu, cmd, MAX_PARTICLES / COMPUTE_PARTICLE_BATCH, 1, 1)
}

// Inside the forward pass. Where textures are bound as groups (WebGPU) particles sample the
// first MAX_PARTICLE_TEXTURES distinct emitter textures; the rest draw untextured.
@(private)
particles_draw :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, camera_index: u32) {
  push := ParticleDrawPush{camera_index = camera_index}
  textures: [MAX_PARTICLE_TEXTURES]TextureHandle
  when !BINDLESS {
    n := 0
    emitters := write_table(self, .EMITTERS, Emitter)[:self.emitter_slots.high_water]
    outer: for &em in emitters {
      if em.texture == 0 || n == MAX_PARTICLE_TEXTURES do continue
      for t in textures[:n] do if t == em.texture do continue outer
      textures[n] = em.texture
      push.textures[n] = u32(em.texture)
      n += 1
    }
  }
  pipeline_bind(self, cmd, self.particle_draw_pipeline, .PARTICLE_DRAW, f, &push, .PARTICLES, ..textures[:])
  dev.cmd_draw_indirect(&self.gpu, cmd, self.buffers[.PARTICLE_ALIVE][0], 0, 1, 0)
}
