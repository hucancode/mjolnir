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
  return particles_gpu_reset(r)
}

// Emitter spawns particles from every slot it is attached to: emission_rate per second (0
// pauses it), each living particle_lifetime seconds and blending from the *_start values to the
// *_end ones. make_emitter fills the defaults; emitter_create stores one.
Emitter :: struct #align(16) {
  initial_velocity:  [3]f32,
  velocity_spread:   f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  position_spread:   f32,
  size_start:        f32,
  size_end:          f32,
  particle_lifetime: f32,
  weight:            f32,
  weight_spread:     f32,
  // particles per second
  emission_rate:     f32,
  // the particles' texture, NO_TEXTURE for none
  texture_index:     TextureHandle,
}
#assert(size_of(Emitter) == 80)

// EmitterHandle identifies an emitter (emitter_create).
EmitterHandle :: distinct u32

// Where an emitter is attached. The emit pass reads the frame's new particles in placement
// order: placement i takes [emit_first, the next placement's emit_first).
@(private)
EmitterPlacement :: struct {
  emitter:    EmitterHandle,
  node:       u32,
  emit_first: u32,
}

// ForceField pulls particles toward every slot it is attached to (push them with a negative
// strength) within area_of_effect (0 pauses it), and swirls them by tangent_strength.
ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
}

// ForceFieldHandle identifies a force field (forcefield_create).
ForceFieldHandle :: distinct u32

@(private)
ForceFieldPlacement :: struct {
  forcefield: ForceFieldHandle,
  node:       u32,
}

// emitter_create stores `e`; attach places it at slots. It lives until emitter_destroy or teardown.
emitter_create :: proc(r: ^Renderer, e: Emitter) -> (handle: EmitterHandle, ok: bool) #optional_ok {
  i := resource_create(r, &r.emitter_slots, .EMITTERS, e) or_return
  return EmitterHandle(i), true
}

// emitter returns the emitter of `h`, to edit in place; every slot it is attached to follows.
emitter :: proc(r: ^Renderer, h: EmitterHandle) -> (^Emitter, bool) #optional_ok {
  return resource(r, &r.emitter_slots, .EMITTERS, Emitter, u32(h))
}

// emitter_destroy frees the emitter; slots it stays attached to emit nothing.
emitter_destroy :: proc(r: ^Renderer, h: EmitterHandle) {
  resource_destroy(r, &r.emitter_slots, .EMITTERS, u32(h))
}

// forcefield_create stores `f`; attach places it at slots. It lives until forcefield_destroy or teardown.
forcefield_create :: proc(r: ^Renderer, f: ForceField) -> (handle: ForceFieldHandle, ok: bool) #optional_ok {
  i := resource_create(r, &r.forcefield_slots, .FORCEFIELDS, f) or_return
  return ForceFieldHandle(i), true
}

// forcefield returns the force field of `h`, to edit in place.
forcefield :: proc(r: ^Renderer, h: ForceFieldHandle) -> (^ForceField, bool) #optional_ok {
  return resource(r, &r.forcefield_slots, .FORCEFIELDS, ForceField, u32(h))
}

// forcefield_destroy frees the force field; slots it stays attached to pull nothing.
forcefield_destroy :: proc(r: ^Renderer, h: ForceFieldHandle) {
  resource_destroy(r, &r.forcefield_slots, .FORCEFIELDS, u32(h))
}

// make_emitter returns an Emitter for emitter_create.
make_emitter :: proc(
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
  }
}

// make_forcefield returns a ForceField for forcefield_create.
make_forcefield :: proc(
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> ForceField {
  return {
    tangent_strength = tangent_strength,
    strength         = strength,
    area_of_effect   = area_of_effect,
  }
}
