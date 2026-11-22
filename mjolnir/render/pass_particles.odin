package render

import "rhi"

// Particles live in a ring buffer of Config.particles slots (oldest overwritten when full).
// Emit spawns each emitter's share at its ring cursor; simulate advances live slots in place
// and appends them to the alive list, whose header is the indirect draw: one point per alive
// particle (Vulkan), or a camera-facing quad of six vertices instanced per alive particle
// (WebGPU points are one pixel).
// init rounds Config.particles up to a multiple
@(private)
COMPUTE_PARTICLE_BATCH :: 256

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
  self.pipelines[.PARTICLE_EMIT] = dev.compute_pipeline_create(
    &self.gpu,
    {shader_source("particle_emit"), pipeline_layout(self, .PARTICLE_EMIT)},
  ) or_return
  self.pipelines[.PARTICLE_SIMULATE] = dev.compute_pipeline_create(
    &self.gpu,
    {shader_source("particle_simulate"), pipeline_layout(self, .PARTICLE_SIMULATE)},
  ) or_return
  self.pipelines[.PARTICLE_DRAW] = dev.graphics_pipeline_create(
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
  self.particle_params.capacity = self.config.particles
  return particles_reset(self)
}

// Kills every particle before the next frame: its draws see none alive, and its simulation
// clears the ring first.
@(private)
particles_reset :: proc(self: ^Renderer) -> bool {
  self.particle_params.emit_cursor = 0
  self.particle_params.emit_total = 0
  self.particles_clear = true
  header := [PARTICLE_ALIVE_HEADER]u32{0, 1, 0, 0} if BINDLESS else {6, 0, 0, 0}
  return dev.buffer_write(&self.gpu, self.buffers[.PARTICLE_ALIVE][0], 0, ([^]u8)(&header)[:size_of(header)])
}

// After drawing: the next frame draws what this simulates. The alive count restarts (and the
// ring after particles_reset), emitters spawn, then every live particle moves and is listed.
@(private)
particles_declare :: proc(self: ^Renderer) {
  particles := buffer_use(self.buffers[.PARTICLES][0], .WRITE)
  alive := buffer_use(self.buffers[.PARTICLE_ALIVE][0], .WRITE)
  declare(self, "particles clear", .TRANSFER, .PARTICLES_CLEAR, 0, as(alive, .COPY_DST), as(particles, .COPY_DST) if self.particles_clear else NO_USE)
  if self.particle_params.emit_total > 0 do declare(self, "particles emit", .COMPUTE, .PARTICLES_EMIT, 0, particles)
  declare(self, "particles simulate", .COMPUTE, .PARTICLES_SIMULATE, 0, particles, alive)
}

// What a draw of the particles reads.
@(private)
particles_use :: proc(self: ^Renderer, uses: ^[dynamic]GraphUse) {
  append(uses, buffer_use(self.buffers[.PARTICLES][0], .READ), buffer_use(self.buffers[.PARTICLE_ALIVE][0], .READ), buffer_use(self.buffers[.PARTICLE_ALIVE][0], .INDIRECT))
}

@(private)
particles_clear_record :: proc(self: ^Renderer, cmd: rhi.CommandList) {
  // the alive count: the vertex count for points, the instance count for quads
  count_word := 0 if BINDLESS else size_of(u32)
  dev.cmd_fill_buffer(&self.gpu, cmd, self.buffers[.PARTICLE_ALIVE][0], count_word, size_of(u32))
  if self.particles_clear do dev.cmd_fill_buffer(&self.gpu, cmd, self.buffers[.PARTICLES][0], 0, self.buffer_sizes[.PARTICLES][0])
  self.particles_clear = false
}

@(private)
particles_emit_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  params := &self.particle_params
  pipeline_bind(self, cmd, self.pipelines[.PARTICLE_EMIT], .PARTICLE_EMIT, f, params, .NONE)
  dev.cmd_dispatch(&self.gpu, cmd, (params.emit_total + 63) / 64, 1, 1)
}

@(private)
particles_simulate_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  params := &self.particle_params
  pipeline_bind(self, cmd, self.pipelines[.PARTICLE_SIMULATE], .PARTICLE_SIMULATE, f, params, .NONE)
  dev.cmd_dispatch(&self.gpu, cmd, params.capacity / COMPUTE_PARTICLE_BATCH, 1, 1)
}

// Inside the forward pass. Where textures are bound as groups (WebGPU) particles sample the
// first MAX_PARTICLE_TEXTURES distinct emitter textures; the rest draw untextured.
@(private)
particles_draw :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, camera_index: u32) {
  push := ParticleDrawPush{camera_index = camera_index}
  textures: [MAX_PARTICLE_TEXTURES]TextureHandle
  when !BINDLESS {
    n := 0
    emitters := write_table(self, .EMITTERS, Emitter)[:self.slots[.EMITTERS].high_water]
    outer: for &em in emitters {
      if em.texture == 0 || n == MAX_PARTICLE_TEXTURES do continue
      for t in textures[:n] do if t == em.texture do continue outer
      textures[n] = em.texture
      push.textures[n] = u32(em.texture)
      n += 1
    }
  }
  pipeline_bind(self, cmd, self.pipelines[.PARTICLE_DRAW], .PARTICLE_DRAW, f, &push, .PARTICLES, ..textures[:])
  dev.cmd_draw_indirect(&self.gpu, cmd, self.buffers[.PARTICLE_ALIVE][0], 0, 1, 0)
}
