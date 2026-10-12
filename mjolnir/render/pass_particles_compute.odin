#+private
// GPU particles: a ring buffer of MAX_PARTICLES slots. Each frame the CPU
// hands every emitter a range of the frame's new particles (an exclusive
// prefix of emit counts) and a ring cursor; the emit pass spawns one particle
// per thread at cursor + thread (oldest slots get overwritten when the ring is
// full). The simulate pass advances every live slot in place and appends it to
// the alive list, whose header is the indirect draw of the live particles.
package render

import "gpu"
import vk "vendor:vulkan"

MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32
#assert(MAX_PARTICLES % COMPUTE_PARTICLE_BATCH == 0)


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

// Emit the frame's new particles, then advance every live particle and list
// it for the next draw.
particles_simulate :: proc(r: ^Manager, cmd: vk.CommandBuffer) {
  params := &r.particle_params
  // The previous simulation and this frame's draws use what gets rewritten.
  gpu.memory_barrier(
    cmd,
    {.SHADER_WRITE},
    {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
    {.DRAW_INDIRECT, .VERTEX_SHADER, .COMPUTE_SHADER},
    {.COMPUTE_SHADER, .TRANSFER},
  )
  vk.CmdFillBuffer(cmd, r.particle_alive_buffer.buffer, 0, size_of(u32), 0)
  push_constants(r, cmd, params)
  if params.emit_total > 0 {
    vk.CmdBindPipeline(cmd, .COMPUTE, r.pipelines[.PARTICLE_EMIT])
    vk.CmdDispatch(cmd, (params.emit_total + 63) / 64, 1, 1)
  }
  gpu.memory_barrier(
    cmd,
    {.SHADER_WRITE, .TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.COMPUTE_SHADER, .TRANSFER},
    {.COMPUTE_SHADER},
  )
  vk.CmdBindPipeline(cmd, .COMPUTE, r.pipelines[.PARTICLE_SIMULATE])
  vk.CmdDispatch(cmd, MAX_PARTICLES / COMPUTE_PARTICLE_BATCH, 1, 1)
}

// Kill every particle and empty the alive list when the next command buffer
// records its uploads.
particles_reset :: proc(r: ^Manager) -> vk.Result {
  r.particle_params.emit_cursor = 0
  r.particle_params.emit_total = 0
  gpu.queue_buffer_fill(&r.gctx, &r.particle_buffer)
  header := [1]vk.DrawIndirectCommand{{instanceCount = 1}}
  return gpu.queue_buffer_write(&r.gctx, &r.particle_alive_buffer, header[:])
}

// The particle ring and the alive list, emptied.
particles_init_buffers :: proc(r: ^Manager) -> vk.Result {
  r.particle_alive_buffer = gpu.buffer_create(
    &r.gctx,
    (PARTICLE_ALIVE_HEADER + MAX_PARTICLES) * size_of(u32),
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    host_visible = false,
  ) or_return
  r.particle_buffer = gpu.buffer_create(
    &r.gctx,
    MAX_PARTICLES * size_of(ParticlesParticle),
    {.STORAGE_BUFFER},
    host_visible = false,
  ) or_return
  return particles_reset(r)
}

particles_init :: proc(r: ^Manager) -> vk.Result {
  gctx := &r.gctx
  layout := r.scene.layout
  r.pipelines[.PARTICLE_EMIT] = gpu.create_compute_pipeline(gctx, #load("shader/particle/emitter.spv"), layout) or_return
  r.pipelines[.PARTICLE_SIMULATE] = gpu.create_compute_pipeline(gctx, #load("shader/particle/compute.spv"), layout) or_return
  desc := gpu.GraphicsPipelineDesc {
    vert     = #load("shader/particle/vert.spv"),
    frag     = #load("shader/particle/frag.spv"),
    topology = .POINT_LIST,
    layout   = layout,
  }
  // drawn in the forward scope
  material_pass_desc(.FORWARD, &desc)
  r.pipelines[.PARTICLE_DRAW] = gpu.create_graphics_pipeline(gctx, desc) or_return
  return .SUCCESS
}

// Draw the live particles listed by the last simulation. Call inside the
// forward render scope, with the camera's index pushed.
particles_draw :: proc(r: ^Manager, cmd: vk.CommandBuffer) {
  vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipelines[.PARTICLE_DRAW])
  vk.CmdDrawIndirect(cmd, r.particle_alive_buffer.buffer, 0, 1, size_of(vk.DrawIndirectCommand))
}
