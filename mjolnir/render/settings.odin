package render

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
  particles_compute.set_params(&self.internal.particles_compute, params)
}

set_visibility_stats_enabled :: proc(self: ^Manager, enabled: bool) {
  self.internal.visibility.stats_enabled = enabled
}
