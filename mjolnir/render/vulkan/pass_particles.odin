package vulkan_backend

import rhi "../rhi"

import vk "vendor:vulkan"



// Particles live in a ring buffer of MAX_PARTICLES slots (oldest overwritten when full).
// Emit spawns each emitter's share at its ring cursor; simulate advances live slots in
// place and appends them to the alive list, whose header is the indirect draw.
@(private)
COMPUTE_PARTICLE_BATCH :: 256
#assert(rhi.MAX_PARTICLES % COMPUTE_PARTICLE_BATCH == 0)

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

@(private)
PARTICLE_ALIVE_HEADER :: size_of(vk.DrawIndirectCommand) / size_of(u32)

@(private)
particles_simulate :: proc(b: ^Backend, cmd: vk.CommandBuffer, params: ^rhi.ParticleSystemParams) {
  // the previous simulation and this frame's draws use what gets rewritten
  barrier(cmd, .PARTICLES_TO_FILL)
  vk.CmdFillBuffer(cmd, b.particle_alive_buffer.buffer, 0, size_of(u32), 0)
  push_constants(b, cmd, params)
  if params.emit_total > 0 {
    vk.CmdBindPipeline(cmd, .COMPUTE, b.pipelines[.PARTICLE_EMIT])
    vk.CmdDispatch(cmd, (params.emit_total + 63) / 64, 1, 1)
  }
  barrier(cmd, .FILL_TO_COMPUTE)
  vk.CmdBindPipeline(cmd, .COMPUTE, b.pipelines[.PARTICLE_SIMULATE])
  vk.CmdDispatch(cmd, rhi.MAX_PARTICLES / COMPUTE_PARTICLE_BATCH, 1, 1)
}

// particles_reset kills every particle before the next frame.
particles_reset :: proc(b: ^Backend) -> bool {
  return check(queue_particles_reset(b), "Particle reset")
}

@(private = "file")
queue_particles_reset :: proc(b: ^Backend) -> vk.Result {
  queue_buffer_fill(&b.gctx, &b.particle_buffer)
  header := [1]vk.DrawIndirectCommand{{instanceCount = 1}}
  return queue_buffer_write(&b.gctx, &b.particle_alive_buffer, header[:])
}

@(private)
particles_init_buffers :: proc(b: ^Backend) -> vk.Result {
  b.particle_alive_buffer = buffer_create(
    &b.gctx,
    (PARTICLE_ALIVE_HEADER + rhi.MAX_PARTICLES) * size_of(u32),
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    host_visible = false,
  ) or_return
  b.particle_buffer = buffer_create(
    &b.gctx,
    rhi.MAX_PARTICLES * size_of(Particle),
    {.STORAGE_BUFFER},
    host_visible = false,
  ) or_return
  return queue_particles_reset(b)
}

@(private)
particles_init :: proc(b: ^Backend) -> vk.Result {
  gctx := &b.gctx
  layout := b.scene.layout
  b.pipelines[.PARTICLE_EMIT] = create_compute_pipeline(gctx, #load("shader/particle/emitter.spv"), layout) or_return
  b.pipelines[.PARTICLE_SIMULATE] = create_compute_pipeline(gctx, #load("shader/particle/compute.spv"), layout) or_return
  desc := GraphicsPipelineDesc {
    vert     = #load("shader/particle/vert.spv"),
    frag     = #load("shader/particle/frag.spv"),
    topology = .POINT_LIST,
    layout   = layout,
  }
  // drawn in the forward scope
  material_pass_desc(.FORWARD, &desc)
  b.pipelines[.PARTICLE_DRAW] = create_graphics_pipeline(gctx, desc) or_return
  return .SUCCESS
}

// Call inside the forward render scope, with the camera's index pushed.
@(private)
particles_draw :: proc(b: ^Backend, cmd: vk.CommandBuffer) {
  vk.CmdBindPipeline(cmd, .GRAPHICS, b.pipelines[.PARTICLE_DRAW])
  vk.CmdDrawIndirect(cmd, b.particle_alive_buffer.buffer, 0, 1, size_of(vk.DrawIndirectCommand))
}
