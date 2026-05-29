package render

import "../gpu"
import particles_compute "particles_compute"

// set_node_count distributes the node count across every culling subsystem
// that needs it for compute dispatch sizing. Caller (engine) is the single
// source of truth.
set_node_count :: proc(self: ^Manager, node_count: u32) {
  n := min(node_count, self.internal.visibility.max_draws)
  self.internal.visibility.node_count = n
  self.internal.depth_pyramid.node_count = n
  self.internal.shadow_culling.node_count = n
  self.internal.shadow_sphere_culling.node_count = n
}

set_particle_params :: proc(
  self: ^Manager,
  params: particles_compute.ParticleSystemParams,
) {
  assert(
    params.emitter_count <= MAX_EMITTERS,
    "emitter_count exceeds MAX_EMITTERS",
  )
  assert(
    params.forcefield_count <= MAX_FORCE_FIELDS,
    "forcefield_count exceeds MAX_FORCE_FIELDS",
  )
  assert(
    params.particle_count <= particles_compute.MAX_PARTICLES,
    "particle_count exceeds MAX_PARTICLES",
  )
  assert(params.delta_time >= 0.0, "delta_time must be non-negative")
  ptr := gpu.get(&self.internal.particles_compute.params_buffer, 0)
  // frame_counter is owned by particles_compute.simulate; preserve it across
  // the per-frame stage updates from the engine.
  preserved := ptr.frame_counter
  ptr^ = params
  ptr.frame_counter = preserved
}

set_visibility_stats_enabled :: proc(self: ^Manager, enabled: bool) {
  self.internal.visibility.stats_enabled = enabled
}

// ---------- ambient (IBL + skybox) setters ----------

set_ibl_intensity :: proc(self: ^Manager, intensity: f32) {
  self.internal.ambient.ibl_intensity = max(intensity, 0.0)
}

get_ibl_intensity :: proc(self: ^Manager) -> f32 {
  return self.internal.ambient.ibl_intensity
}

set_skybox_enabled :: proc(self: ^Manager, enabled: bool) {
  self.internal.ambient.skybox_enabled = enabled
}

get_skybox_enabled :: proc(self: ^Manager) -> bool {
  return self.internal.ambient.skybox_enabled
}

set_skybox_intensity :: proc(self: ^Manager, intensity: f32) {
  self.internal.ambient.skybox_intensity = max(intensity, 0.0)
}

get_skybox_intensity :: proc(self: ^Manager) -> f32 {
  return self.internal.ambient.skybox_intensity
}

set_skybox_blur :: proc(self: ^Manager, blur: f32) {
  self.internal.ambient.skybox_blur = clamp(blur, 0.0, 1.0)
}

get_skybox_blur :: proc(self: ^Manager) -> f32 {
  return self.internal.ambient.skybox_blur
}

mesh_destroy :: proc(render: ^Manager, handle: u32) {
  mesh := gpu.mutable_buffer_get(&render.internal.mesh_data_buffer.buffer, handle)
  if mesh.index_count > 0 {
    gpu.free_vertices(
      &render.mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
  }
  if .SKINNED in mesh.flags {
    gpu.free_vertex_skinning(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.skinning_offset, count = 1},
    )
  }
  mesh^ = {}
}
