package render

// Emitters spawn into the backend's particle ring of MAX_PARTICLES (flush_particles).
@(private)
MAX_EMITTERS :: 64
@(private)
MAX_FORCE_FIELDS :: 32

// Emitter spawns particles from every slot it is attached to: emission_rate per second (0
// pauses it), each living particle_lifetime seconds and blending from the *_start values to the
// *_end ones. size_* is a particle's side in pixels seen from 1 unit away, shrinking with
// distance. make_emitter fills the defaults; emitter_create stores one.
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
  texture:           TextureHandle,
  // per second, the fraction of speed a particle sheds: 0 flies free, 4 stops within about a second
  drag:              f32,
  _pad:              [3]f32,
}
#assert(size_of(Emitter) == 96)

// EmitterHandle identifies an emitter (emitter_create).
EmitterHandle :: distinct u32

// A one-shot emission (emit): count particles at slot, queued until the next flush, which gives
// it placement row `row` for that frame only.
@(private)
Burst :: struct {
  emitter: EmitterHandle,
  slot:    u32,
  count:   u32,
  row:     u32,
}

// Where an emitter is attached, or a burst's row for one frame (`burst` particles, 0 for an
// attachment). The emit pass reads the frame's new particles in placement order: placement i
// takes [emit_first, the next placement's emit_first).
@(private)
EmitterPlacement :: struct {
  emitter:    EmitterHandle,
  node:       u32,
  emit_first: u32,
  burst:      u32,
}

// ForceField pulls particles toward every slot it is attached to (push them with a negative
// strength) within area_of_effect (0 pauses it), and swirls them by tangent_strength.
ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
}

// ForceFieldHandle identifies a force field (force_field_create).
ForceFieldHandle :: distinct u32

@(private)
ForceFieldPlacement :: struct {
  force_field: ForceFieldHandle,
  node:       u32,
}

// emitter_create stores `e`; attach places it at slots. It lives until emitter_destroy or teardown.
emitter_create :: proc(self: ^Renderer, e: Emitter) -> (handle: EmitterHandle, ok: bool) #optional_ok {
  i := resource_create(self, .EMITTERS, e) or_return
  return EmitterHandle(i), true
}

// emitter returns the emitter of `handle`, to edit in place; every slot it is attached to
// follows. The pointer is valid for this tick: getting it marks the data for upload, so get
// it again next tick.
emitter :: proc(self: ^Renderer, handle: EmitterHandle) -> (^Emitter, bool) #optional_ok {
  return resource(self, .EMITTERS, Emitter, u32(handle))
}

// emit spawns count particles of emitter once, from slot's transform, on the next frame,
// whatever its emission_rate (an emitter whose rate is 0 only bursts). A slot removed before
// then emits nothing.
emit :: proc(self: ^Renderer, emitter: EmitterHandle, slot: $H, count: u32) {
  if count == 0 do return
  guard(self)
  append(&self.bursts, Burst{emitter = emitter, slot = slot_index(slot), count = count})
}

// emitter_destroy frees the emitter; slots it stays attached to emit nothing.
emitter_destroy :: proc(self: ^Renderer, handle: EmitterHandle) {
  resource_destroy(self, .EMITTERS, u32(handle))
}

// force_field_create stores `f`; attach places it at slots. It lives until force_field_destroy or teardown.
force_field_create :: proc(self: ^Renderer, f: ForceField) -> (handle: ForceFieldHandle, ok: bool) #optional_ok {
  i := resource_create(self, .FORCE_FIELDS, f) or_return
  return ForceFieldHandle(i), true
}

// force_field returns the force field of `handle`, to edit in place; the pointer is valid for
// this tick: getting it marks the data for upload, so get it again next tick.
force_field :: proc(self: ^Renderer, handle: ForceFieldHandle) -> (^ForceField, bool) #optional_ok {
  return resource(self, .FORCE_FIELDS, ForceField, u32(handle))
}

// force_field_destroy frees the force field; slots it stays attached to pull nothing.
force_field_destroy :: proc(self: ^Renderer, handle: ForceFieldHandle) {
  resource_destroy(self, .FORCE_FIELDS, u32(handle))
}

// make_emitter returns an Emitter for emitter_create.
make_emitter :: proc(
  texture: TextureHandle = 0,
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
  drag: f32 = 0.0,
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
    texture           = texture,
    drag              = drag,
  }
}

// make_force_field returns a ForceField for force_field_create.
make_force_field :: proc(
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
