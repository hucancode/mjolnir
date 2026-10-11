#+private
// GPU particles: a ring buffer of MAX_PARTICLES slots. Each frame the emit
// pass writes new particles at an atomic cursor (oldest slots get overwritten
// when the ring is full), the particles_simulate pass advances every live slot in
// place, and the draw covers all slots, discarding dead ones in the vertex
// shader.
//
// With async compute the simulation runs on a separate queue and the graphics
// queue only waits for it before drawing. Frame N+1's simulation may therefore
// overlap frame N's particle draw, which can then see a mix of old and new
// particle state for that frame.
package render

import "gpu"
import "core:log"
import "core:slice"
import vk "vendor:vulkan"

MAX_PARTICLES :: 65536
COMPUTE_PARTICLE_BATCH :: 256
MAX_EMITTERS :: 64
MAX_FORCE_FIELDS :: 32

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
  emit_count:        u32,
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
}

ParticlesRenderer :: struct {
  // this frame's simulation inputs, pushed to both compute passes
  params:                             ParticleSystemParams,
  // Next ring slot to emit into; grows forever, read modulo MAX_PARTICLES.
  cursor_buffer:                      gpu.MutableBuffer(u32),
  particle_buffer:                    gpu.MutableBuffer(ParticlesParticle),
  // particle_buffer, cursor_buffer; shared by emit, particles_simulate and
  // draw.
  descriptor_set_layout:              vk.DescriptorSetLayout,
  descriptor_set:                     vk.DescriptorSet,
  emitter_pipeline_layout:            vk.PipelineLayout,
  emitter_pipeline:                   vk.Pipeline,
  compute_pipeline_layout:            vk.PipelineLayout,
  compute_pipeline:                   vk.Pipeline,
  render_pipeline_layout:             vk.PipelineLayout,
  render_pipeline:                    vk.Pipeline,
}

particles_simulate :: proc(
  self: ^ParticlesRenderer,
  command_buffer: vk.CommandBuffer,
  emitter_set: vk.DescriptorSet,
  forcefield_set: vk.DescriptorSet,
  node_data_set: vk.DescriptorSet,
) {
  gpu.bind_pipeline(
    command_buffer,
    .COMPUTE,
    self.emitter_pipeline,
    self.emitter_pipeline_layout,
    emitter_set,
    self.descriptor_set,
    node_data_set,
  )
  vk.CmdPushConstants(command_buffer, self.emitter_pipeline_layout, {.COMPUTE}, 0, size_of(self.params), &self.params)
  // One thread per emitter (local_size_x = 64)
  vk.CmdDispatch(command_buffer, u32(MAX_EMITTERS + 63) / 64, 1, 1)
  gpu.memory_barrier(
    command_buffer,
    {.SHADER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
  )
  gpu.bind_pipeline(
    command_buffer,
    .COMPUTE,
    self.compute_pipeline,
    self.compute_pipeline_layout,
    self.descriptor_set,
    forcefield_set,
    node_data_set,
  )
  vk.CmdPushConstants(command_buffer, self.compute_pipeline_layout, {.COMPUTE}, 0, size_of(self.params), &self.params)
  vk.CmdDispatch(
    command_buffer,
    u32(MAX_PARTICLES + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH,
    1,
    1,
  )
  // Orders this frame's simulation before the next frame's emission.
  gpu.memory_barrier(
    command_buffer,
    {.SHADER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
  )
}

// Kill every particle and restart the emit cursor.
particles_reset :: proc(self: ^ParticlesRenderer) {
  slice.zero(gpu.get_all(&self.particle_buffer))
  gpu.get(&self.cursor_buffer)^ = 0
}

particles_shutdown :: proc(self: ^ParticlesRenderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.render_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.render_pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.compute_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.compute_pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.emitter_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.emitter_pipeline_layout, nil)
  gpu.free_descriptor_sets(gctx, self.descriptor_set)
  vk.DestroyDescriptorSetLayout(gctx.device, self.descriptor_set_layout, nil)
  gpu.mutable_buffer_destroy(gctx.device, &self.cursor_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_buffer)
}

particles_init :: proc(
  self: ^ParticlesRenderer,
  gctx: ^gpu.GPUContext,
  emitter_set_layout: vk.DescriptorSetLayout,
  forcefield_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debugf("Initializing particle renderer")
  defer if ret != .SUCCESS do particles_shutdown(self, gctx)
  self.cursor_buffer = gpu.create_mutable_buffer(gctx, u32, 1, {.STORAGE_BUFFER}) or_return
  self.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    ParticlesParticle,
    MAX_PARTICLES,
    {.STORAGE_BUFFER},
  ) or_return
  particles_reset(self)

  self.descriptor_set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE, .VERTEX}},
    {.STORAGE_BUFFER, {.COMPUTE}},
  ) or_return
  self.descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.descriptor_set_layout,
    {.STORAGE_BUFFER, gpu.buffer_info(&self.particle_buffer)},
    {.STORAGE_BUFFER, gpu.buffer_info(&self.cursor_buffer)},
  ) or_return

  params_range := vk.PushConstantRange{stageFlags = {.COMPUTE}, size = size_of(ParticleSystemParams)}
  self.emitter_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    params_range,
    emitter_set_layout,
    self.descriptor_set_layout,
    node_data_set_layout,
  ) or_return
  self.emitter_pipeline = gpu.create_compute_pipeline(
    gctx,
    SHADER_EMITTER_COMP,
    self.emitter_pipeline_layout,
  ) or_return

  self.compute_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    params_range,
    self.descriptor_set_layout,
    forcefield_set_layout,
    node_data_set_layout,
  ) or_return
  self.compute_pipeline = gpu.create_compute_pipeline(
    gctx,
    SHADER_PARTICLE_COMP,
    self.compute_pipeline_layout,
  ) or_return

  particles_create_render_pipeline(gctx, self, camera_set_layout, textures_set_layout) or_return
  return .SUCCESS
}
