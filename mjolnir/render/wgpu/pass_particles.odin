package wgpu_backend

import wgpu "vendor:wgpu"

MAX_PARTICLES :: 65536

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

// Particles live in a ring buffer of MAX_PARTICLES slots (oldest overwritten when full).
// Emit spawns each emitter's share at its ring cursor; simulate advances live slots in place
// and appends them to the alive list, whose header is the indirect draw: a camera-facing quad
// (six vertices) per alive particle, instanced (WebGPU points are one pixel).
@(private)
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

// vertex count, instance count (the alive particles), first vertex, first instance
@(private)
PARTICLE_ALIVE_HEADER :: 4

// Render's emitter entry, as far as the draw reads it: its texture.
@(private = "file")
EmitterData :: struct {
  _:       [19]u32,
  texture: TextureHandle,
  _:       [4]u32,
}
#assert(size_of(EmitterData) == 96)

@(private = "file")
ParticleDrawUniforms :: struct {
  camera_index: u32,
  _:            [3]u32,
  // the texture handle each slot of the particle group holds
  textures:     [MAX_PARTICLE_TEXTURES]u32,
}

@(private = "file")
EMIT_WGSL :: #load("shader/common.wgsl", string) + #load("shader/particle_emit.wgsl", string)
@(private = "file")
SIMULATE_WGSL :: #load("shader/common.wgsl", string) + #load("shader/particle_simulate.wgsl", string)
@(private = "file")
DRAW_WGSL :: #load("shader/common.wgsl", string) + #load("shader/particle.wgsl", string)

@(private)
particles_init_buffers :: proc(b: ^Backend) {
  b.particle_alive_buffer = buffer_create(b, (PARTICLE_ALIVE_HEADER + MAX_PARTICLES) * size_of(u32), {.Storage, .Indirect, .CopyDst})
  b.particle_buffer = buffer_create(b, MAX_PARTICLES * size_of(Particle), {.Storage, .CopyDst})
}

@(private)
particles_init :: proc(b: ^Backend) {
  b.particle_emit_pipeline = compute_pipeline(b, EMIT_WGSL, .PARTICLE_EMIT, .NONE)
  b.particle_simulate_pipeline = compute_pipeline(b, SIMULATE_WGSL, .PARTICLE_SIMULATE, .NONE)
  desc := GraphicsPipelineDesc {
    source   = DRAW_WGSL,
    scene    = .PARTICLE_DRAW,
    textures = .PARTICLES,
    topology = .TriangleList,
  }
  // drawn in the forward pass
  material_pass_desc(.FORWARD, &desc)
  b.particle_draw_pipeline = graphics_pipeline(b, desc)
  particles_reset(b)
}

// particles_reset kills every particle before the next frame.
particles_reset :: proc(b: ^Backend) -> bool {
  encoder := wgpu.DeviceCreateCommandEncoder(b.device)
  wgpu.CommandEncoderClearBuffer(encoder, b.particle_buffer, 0, wgpu.BufferGetSize(b.particle_buffer))
  commands := wgpu.CommandEncoderFinish(encoder)
  wgpu.QueueSubmit(b.queue, {commands})
  wgpu.CommandBufferRelease(commands)
  wgpu.CommandEncoderRelease(encoder)
  header := [PARTICLE_ALIVE_HEADER]u32{6, 0, 0, 0}
  wgpu.QueueWriteBuffer(b.queue, b.particle_alive_buffer, 0, &header, size_of(header))
  return true
}

// After drawing: the next frame draws what this simulates.
@(private)
particles_simulate :: proc(b: ^Backend, encoder: wgpu.CommandEncoder, params: ^ParticleSystemParams) {
  // the instance count; the vertex count stays six
  wgpu.CommandEncoderClearBuffer(encoder, b.particle_alive_buffer, size_of(u32), size_of(u32))
  pass := wgpu.CommandEncoderBeginComputePass(encoder)
  defer {
    wgpu.ComputePassEncoderEnd(pass)
    wgpu.ComputePassEncoderRelease(pass)
  }
  offset := uniform(b, params)
  wgpu.ComputePassEncoderSetBindGroup(pass, 1, group(b, {layout = .NONE}))
  wgpu.ComputePassEncoderSetBindGroup(pass, 2, b.frame_group, {offset})
  if params.emit_total > 0 {
    wgpu.ComputePassEncoderSetPipeline(pass, b.particle_emit_pipeline)
    wgpu.ComputePassEncoderSetBindGroup(pass, 0, b.scene_groups[.PARTICLE_EMIT])
    wgpu.ComputePassEncoderDispatchWorkgroups(pass, (params.emit_total + 63) / 64, 1, 1)
  }
  wgpu.ComputePassEncoderSetPipeline(pass, b.particle_simulate_pipeline)
  wgpu.ComputePassEncoderSetBindGroup(pass, 0, b.scene_groups[.PARTICLE_SIMULATE])
  wgpu.ComputePassEncoderDispatchWorkgroups(pass, MAX_PARTICLES / COMPUTE_PARTICLE_BATCH, 1, 1)
}

// Inside the forward pass, after the camera's uniforms are bound. Particles sample the first
// MAX_PARTICLE_TEXTURES distinct emitter textures; the rest draw untextured.
@(private)
particles_draw :: proc(b: ^Backend, desc: ^FrameDesc, rp: wgpu.RenderPassEncoder, camera_index: u32) {
  u := ParticleDrawUniforms{camera_index = camera_index}
  key := GroupKey{layout = .PARTICLES}
  n := 0
  emitters := table(desc, .EMITTERS, EmitterData)[:desc.particle_params.emitter_count]
  outer: for &em in emitters {
    if em.texture == 0 || n == MAX_PARTICLE_TEXTURES do continue
    for t in key.textures[:n] do if t == em.texture do continue outer
    key.textures[n] = em.texture
    u.textures[n] = u32(em.texture)
    n += 1
  }
  offset := uniform(b, &u)
  wgpu.RenderPassEncoderSetPipeline(rp, b.particle_draw_pipeline)
  wgpu.RenderPassEncoderSetBindGroup(rp, 0, b.scene_groups[.PARTICLE_DRAW])
  wgpu.RenderPassEncoderSetBindGroup(rp, 1, group(b, key))
  wgpu.RenderPassEncoderSetBindGroup(rp, 2, b.frame_group, {offset})
  wgpu.RenderPassEncoderDrawIndirect(rp, b.particle_alive_buffer, 0)
}
