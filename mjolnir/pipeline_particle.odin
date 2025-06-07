package mjolnir

import linalg "core:math/linalg"
import "geometry"

Particle :: struct {
  position:    linalg.Vector3f32,
  size:        f32,
  velocity:    linalg.Vector3f32,
  lifetime:    f32,
  color_start: linalg.Vector4f32,
  color_end:   linalg.Vector4f32,
}

Emitter :: struct {
  transform:         geometry.Transform,
  emission_rate:     f32, // Particles per second
  particle_lifetime: f32,
  initial_velocity:  linalg.Vector3f32,
  velocity_spread:   f32,
  color_start:       linalg.Vector4f32, // Start color (RGBA)
  color_end:         linalg.Vector4f32, // End color (RGBA)
  size_start:        f32,
  size_end:          f32,
  enabled:           bool,
  time_accumulator:  f32,
}
