#+private
// GPU particles: a ring buffer of MAX_PARTICLES slots. Each frame the CPU
// hands every emitter a range of the frame's new particles (an exclusive
// prefix of emit counts) and a ring cursor; the emit pass spawns one particle
// per thread at cursor + thread (oldest slots get overwritten when the ring is
// full). The simulate pass advances every live slot in place and appends it to
// the alive list, whose header is the indirect draw of the live particles.
package render

import "gpu"
import "core:log"
import vk "vendor:vulkan"

MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32
#assert(MAX_PARTICLES % COMPUTE_PARTICLE_BATCH == 0)

SHADER_EMITTER_COMP :: #load("shader/particle/emitter.spv")
SHADER_PARTICLE_COMP :: #load("shader/particle/compute.spv")

// A slot is dead when life <= 0.
ParticlesParticle :: struct {
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

// std430 rounds the struct to 16 bytes (it holds vec4s); #align(16) keeps the
// Odin array stride equal to the GLSL one.
EmitterData :: struct #align(16) {
  initial_velocity:  [3]f32,
  size_start:        f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  // first of this emitter's particles among the frame's new particles
  emit_first:        u32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  texture_index:     u32,
  node_index:        u32,
}

ForceFieldData :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  node_index:       u32,
}

ParticleSystemParams :: struct {
  emitter_count:    u32,
  forcefield_count: u32,
  delta_time:       f32,
  frame_counter:    u32,
  // new particles this frame, all emitters together
  emit_total:       u32,
  // ring slot of the frame's first new particle
  emit_cursor:      u32,
}

// The alive list: an indirect draw whose vertex count the simulation bumps,
// followed by one particle index per vertex.
PARTICLE_ALIVE_HEADER :: size_of(vk.DrawIndirectCommand) / size_of(u32)

ParticlesRenderer :: struct {
  // this frame's simulation inputs, pushed to both compute passes
  params:           ParticleSystemParams,
  alive_buffer:     gpu.Buffer,
  particle_buffer:  gpu.Buffer,
  emitter_pipeline: vk.Pipeline,
  compute_pipeline: vk.Pipeline,
  render_pipeline:  vk.Pipeline,
}

// Emit the frame's new particles, then advance every live particle and list
// it for the next draw.
particles_simulate :: proc(r: ^Manager, cmd: vk.CommandBuffer) {
  self := &r.internal.particles
  // The previous simulation and this frame's draws use what gets rewritten.
  gpu.memory_barrier(
    cmd,
    {.SHADER_WRITE},
    {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
    {.DRAW_INDIRECT, .VERTEX_SHADER, .COMPUTE_SHADER},
    {.COMPUTE_SHADER, .TRANSFER},
  )
  vk.CmdFillBuffer(cmd, self.alive_buffer.buffer, 0, size_of(u32), 0)
  push_constants(r, cmd, &self.params)
  if self.params.emit_total > 0 {
    vk.CmdBindPipeline(cmd, .COMPUTE, self.emitter_pipeline)
    vk.CmdDispatch(cmd, (self.params.emit_total + 63) / 64, 1, 1)
  }
  gpu.memory_barrier(
    cmd,
    {.SHADER_WRITE, .TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.COMPUTE_SHADER, .TRANSFER},
    {.COMPUTE_SHADER},
  )
  vk.CmdBindPipeline(cmd, .COMPUTE, self.compute_pipeline)
  vk.CmdDispatch(cmd, MAX_PARTICLES / COMPUTE_PARTICLE_BATCH, 1, 1)
}

// Kill every particle and empty the alive list when the next command buffer
// records its uploads.
particles_reset :: proc(self: ^ParticlesRenderer, gctx: ^gpu.GPUContext) -> vk.Result {
  self.params.emit_cursor = 0
  self.params.emit_total = 0
  gpu.queue_buffer_fill(gctx, &self.particle_buffer)
  header := [1]vk.DrawIndirectCommand{{instanceCount = 1}}
  return gpu.queue_buffer_write(gctx, &self.alive_buffer, header[:])
}

particles_init_buffers :: proc(self: ^ParticlesRenderer, gctx: ^gpu.GPUContext) -> vk.Result {
  self.alive_buffer = gpu.buffer_create(
    gctx,
    (PARTICLE_ALIVE_HEADER + MAX_PARTICLES) * size_of(u32),
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    host_visible = false,
  ) or_return
  self.particle_buffer = gpu.buffer_create(
    gctx,
    MAX_PARTICLES * size_of(ParticlesParticle),
    {.STORAGE_BUFFER},
    host_visible = false,
  ) or_return
  return particles_reset(self, gctx)
}

particles_destroy_buffers :: proc(self: ^ParticlesRenderer, gctx: ^gpu.GPUContext) {
  gpu.buffer_destroy(gctx.device, &self.alive_buffer)
  gpu.buffer_destroy(gctx.device, &self.particle_buffer)
}

particles_shutdown :: proc(self: ^ParticlesRenderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.compute_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.emitter_pipeline, nil)
  self.render_pipeline = 0
  self.compute_pipeline = 0
  self.emitter_pipeline = 0
}

particles_init :: proc(r: ^Manager) -> (ret: vk.Result) {
  self := &r.internal.particles
  gctx := &r.gctx
  log.debugf("Initializing particle renderer")
  defer if ret != .SUCCESS do particles_shutdown(self, gctx)
  layout := r.internal.scene.layout
  self.emitter_pipeline = gpu.create_compute_pipeline(gctx, SHADER_EMITTER_COMP, layout) or_return
  self.compute_pipeline = gpu.create_compute_pipeline(gctx, SHADER_PARTICLE_COMP, layout) or_return
  particles_create_render_pipeline(r) or_return
  return .SUCCESS
}
