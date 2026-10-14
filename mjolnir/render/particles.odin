package render

// Emitters spawn into the backend's particle ring of MAX_PARTICLES (flush_particles).
@(private)
MAX_EMITTERS :: 64
@(private)
MAX_FORCE_FIELDS :: 32

@(private)
particles_reset :: proc(r: ^Renderer) -> bool {
  r.particle_params.emit_cursor = 0
  r.particle_params.emit_total = 0
  return backend_particles_reset(&r.gpu)
}

// Emitter is stored as the emit shader reads it; #align(16) keeps the array stride equal to
// std430's. Attached to a slot it spawns particles from the slot's transform.
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
  // transform slot the particles spawn from; attach sets it
  node_index:        u32,
  // particles per second while enabled
  emission_rate:     f32,
  enabled:           b32,
  _:                 f32,
}
#assert(size_of(Emitter) == 96)

// ForceField is stored as the simulation reads it. Attached to a slot it is centered on
// the slot's transform.
ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  // transform slot the field is centered on; attach sets it
  node_index:       u32,
  enabled:          b32,
}
#assert(size_of(ForceField) == 20)

// emitter_attachment returns an enabled Emitter for attach.
emitter_attachment :: proc(
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
) -> Emitter {
  return {
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
}

// forcefield_attachment returns an enabled ForceField for attach.
forcefield_attachment :: proc(
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> ForceField {
  return {
    tangent_strength = tangent_strength,
    strength         = strength,
    area_of_effect   = area_of_effect,
    enabled          = true,
  }
}
