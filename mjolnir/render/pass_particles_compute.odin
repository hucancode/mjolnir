package render

import "core:sync"
import "gpu"
import cont "../containers"
import vk "vendor:vulkan"

// GPU particles live in a ring buffer of MAX_PARTICLES slots. Each frame the
// CPU hands every emitter a range of the frame's new particles (an exclusive
// prefix of emit counts) and a ring cursor; the emit pass spawns one particle
// per thread at cursor + thread (oldest slots get overwritten when the ring is
// full). The simulate pass advances every live slot in place and appends it to
// the alive list, whose header is the indirect draw of the live particles.
@(private)
MAX_PARTICLES :: 65536
@(private)
COMPUTE_PARTICLE_BATCH :: 256
@(private)
MAX_EMITTERS :: 64
@(private)
MAX_FORCE_FIELDS :: 32
#assert(MAX_PARTICLES % COMPUTE_PARTICLE_BATCH == 0)

// a slot is dead when life <= 0
@(private)
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

@(private)
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

@(private)
PARTICLE_ALIVE_HEADER :: size_of(vk.DrawIndirectCommand) / size_of(u32)

@(private)
particles_simulate :: proc(r: ^Renderer, cmd: vk.CommandBuffer) {
  params := &r.particle_params
  // the previous simulation and this frame's draws use what gets rewritten
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

@(private)
particles_reset :: proc(r: ^Renderer) -> vk.Result {
  r.particle_params.emit_cursor = 0
  r.particle_params.emit_total = 0
  gpu.queue_buffer_fill(&r.gctx, &r.particle_buffer)
  header := [1]vk.DrawIndirectCommand{{instanceCount = 1}}
  return gpu.queue_buffer_write(&r.gctx, &r.particle_alive_buffer, header[:])
}

@(private)
particles_init_buffers :: proc(r: ^Renderer) -> vk.Result {
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

@(private)
particles_init :: proc(r: ^Renderer) -> vk.Result {
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

// Call inside the forward render scope, with the camera's index pushed.
@(private)
particles_draw :: proc(r: ^Renderer, cmd: vk.CommandBuffer) {
  vk.CmdBindPipeline(cmd, .GRAPHICS, r.pipelines[.PARTICLE_DRAW])
  vk.CmdDrawIndirect(cmd, r.particle_alive_buffer.buffer, 0, 1, size_of(vk.DrawIndirectCommand))
}

// Emitter is stored as the emit shader reads it; #align(16) keeps the array stride equal to std430's.
Emitter :: struct #align(16) {
  initial_velocity:  [3]f32,
  size_start:        f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  // first of this emitter's particles among the frame's new particles;
  // render writes it every frame
  emit_first:        u32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  // bindless texture of the particles, NO_TEXTURE for none
  texture_index:     TextureHandle,
  // transform slot the particles spawn from, set by attach
  node_index:        u32,
  // particles per second while enabled
  emission_rate:     f32,
  enabled:           b32,
  // fraction of a particle carried to the next frame; render writes it
  emit_carry:        f32,
}
#assert(size_of(Emitter) == 96)

// ForceField is stored as the simulation reads it.
ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  // transform slot the field is centered on, set by attach
  node_index:       u32,
  enabled:          b32,
}

// emitter returns a pointer to the emitter of h in the table the next frame reads; edit it in place.
emitter :: proc(r: ^Renderer, h: EmitterHandle) -> (^Emitter, bool) #optional_ok {
  if !cont.slots_live(&r.emitter_slots, u32(h)) do return nil, false
  mark_dirty(r, .EMITTERS, Emitter, int(h))
  return &write_table(r, .EMITTERS, Emitter)[h], true
}

// forcefield returns a pointer to the force field of h in the table the next frame reads.
forcefield :: proc(r: ^Renderer, h: ForceFieldHandle) -> (^ForceField, bool) #optional_ok {
  if !cont.slots_live(&r.forcefield_slots, u32(h)) do return nil, false
  mark_dirty(r, .FORCEFIELDS, ForceField, int(h))
  return &write_table(r, .FORCEFIELDS, ForceField)[h], true
}

// create_emitter allocates an emitter with the given parameters, enabled and unattached.
create_emitter :: proc(
  self: ^Renderer,
  texture_handle: TextureHandle = 0,
  emission_rate: f32 = 50.0,
  initial_velocity: [3]f32 = {0, 1, 0},
  velocity_spread: f32 = 0.5,
  color_start: [4]f32 = {1, 1, 1, 1},
  color_end: [4]f32 = {1, 1, 1, 0},
  particle_lifetime: f32 = 2.0,
  position_spread: f32 = 0.0,
  size_start: f32 = 100.0,
  size_end: f32 = 100.0,
  weight: f32 = 1.0,
  weight_spread: f32 = 0.0,
) -> (
  ret: EmitterHandle,
  ok: bool,
) #optional_ok {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle := EmitterHandle(cont.slots_alloc(&self.emitter_slots) or_return)
  emitter(self, handle)^ = {
    emission_rate     = emission_rate,
    initial_velocity  = initial_velocity,
    velocity_spread   = velocity_spread,
    color_start       = color_start,
    color_end         = color_end,
    particle_lifetime = particle_lifetime,
    position_spread   = position_spread,
    size_start        = size_start,
    size_end          = size_end,
    weight            = weight,
    weight_spread     = weight_spread,
    texture_index     = texture_handle,
    enabled           = true,
  }
  return handle, true
}

// destroy_emitter frees the emitter slot; false if h is not live.
destroy_emitter :: proc(self: ^Renderer, handle: EmitterHandle) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  cont.slots_free(&self.emitter_slots, u32(handle)) or_return
  clear_entry(self, .EMITTERS, Emitter, u32(handle))
  return true
}

// create_forcefield allocates an enabled, unattached force field.
create_forcefield :: proc(
  self: ^Renderer,
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (
  ret: ForceFieldHandle,
  ok: bool,
) #optional_ok {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle := ForceFieldHandle(cont.slots_alloc(&self.forcefield_slots) or_return)
  forcefield(self, handle)^ = {
    tangent_strength = tangent_strength,
    strength         = strength,
    area_of_effect   = area_of_effect,
    enabled          = true,
  }
  return handle, true
}

// destroy_forcefield frees the force field slot; false if handle is not live.
destroy_forcefield :: proc(self: ^Renderer, handle: ForceFieldHandle) -> bool {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  cont.slots_free(&self.forcefield_slots, u32(handle)) or_return
  clear_entry(self, .FORCEFIELDS, ForceField, u32(handle))
  return true
}
