package render

import "../gpu"
import particles_compute "particles_compute"

// Store the active scene node count (clamped to MAX_NODES_IN_SCENE). Culling
// and depth pyramid dispatch reads it per-frame from Manager.node_count.
set_node_count :: proc(self: ^Manager, node_count: u32) {
  self.node_count = min(node_count, self.internal.visibility.max_draws)
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
// Internal struct is package-private, so external callers cannot reach the
// ambient renderer directly. These wrappers gate access until ambient is
// promoted to the public Manager surface.

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
