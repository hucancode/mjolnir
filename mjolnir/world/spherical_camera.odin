package world

import d "../data"

spherical_camera_init :: proc(
  self: ^d.SphericalCamera,
  size: u32,
  center: [3]f32 = {0, 0, 0},
  radius: f32 = 1.0,
  near: f32 = 0.1,
  far: f32 = 100.0,
  max_draws: u32 = d.MAX_NODES_IN_SCENE,
) -> bool {
  // Initialize CPU-only fields
  self.center = center
  self.radius = radius
  self.near = near
  self.far = far
  self.size = size
  self.max_draws = max_draws
  return true
}

spherical_camera_destroy :: proc(
  self: ^d.SphericalCamera,
) {
  // CPU-only spherical camera data needs no explicit destroy.
}
