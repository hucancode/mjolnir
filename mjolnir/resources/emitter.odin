package resources

import "../geometry"

EmitterData :: struct {
  initial_velocity:  [4]f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  emission_rate:     f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  time_accumulator:  f32,
  size_start:        f32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  texture_index:     u32,
  node_index:        u32,
  visible:           b32,
  aabb_min:          [3]f32,
  padding1:           f32,
  aabb_max:          [3]f32,
  padding2:          f32,
}

Emitter :: struct {
  using data:        EmitterData,
  enabled:           b32,
  texture_handle:    Handle,
  node_handle:       Handle,
}
