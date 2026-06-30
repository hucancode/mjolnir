package world

import cont "../containers"
import "../gpu"

Emitter :: struct {
  initial_velocity:  [3]f32,
  size_start:        f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  aabb_min:          [3]f32,
  emission_rate:     f32,
  aabb_max:          [3]f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  // Fractional carryover of emissions; advanced each frame by tick_emitters.
  // Lives on CPU so per-frame restaging does not clobber sub-particle progress
  // when emission_rate * delta_time < 1.
  time_accumulator:  f32,
  pending_emit:      u32,
  enabled:           b32,
  texture_handle:    gpu.Texture2DHandle,
  node_handle:       NodeHandle,
}

create_emitter :: proc(
  world: ^World,
  node_handle: NodeHandle = {},
  texture_handle: gpu.Texture2DHandle = {},
  emission_rate: f32 = 50.0,
  initial_velocity: [3]f32 = {0, 1, 0},
  velocity_spread: f32 = 0.5,
  color_start: [4]f32 = {1, 1, 1, 1},
  color_end: [4]f32 = {1, 1, 1, 0},
  aabb_min: [3]f32 = {-10, -10, -10},
  aabb_max: [3]f32 = {10, 10, 10},
  particle_lifetime: f32 = 2.0,
  position_spread: f32 = 0.0,
  size_start: f32 = 100.0,
  size_end: f32 = 100.0,
  weight: f32 = 1.0,
  weight_spread: f32 = 0.0,
) -> (
  ret: EmitterHandle,
  ok: bool,
) #optional_ok {
  handle, emitter := cont.alloc(&world.emitters, EmitterHandle) or_return
  emitter.emission_rate = emission_rate
  emitter.initial_velocity = initial_velocity
  emitter.velocity_spread = velocity_spread
  emitter.color_start = color_start
  emitter.color_end = color_end
  emitter.aabb_min = aabb_min
  emitter.aabb_max = aabb_max
  emitter.particle_lifetime = particle_lifetime
  emitter.position_spread = position_spread
  emitter.size_start = size_start
  emitter.size_end = size_end
  emitter.weight = weight
  emitter.weight_spread = weight_spread
  emitter.node_handle = node_handle
  emitter.texture_handle = texture_handle
  emitter.enabled = true
  stage_emitter_data(&world.staging, handle)
  return handle, true
}

destroy_emitter :: proc(world: ^World, handle: EmitterHandle) -> bool {
  return cont.free_deferred(&world.emitters, handle)
}

tick_emitters :: proc(world: ^World, delta_time: f32) {
  for &entry, idx in world.emitters.entries {
    if entry.generation == 0 || !entry.active do continue
    em := &entry.item
    if !bool(em.enabled) {
      em.time_accumulator = 0
      em.pending_emit = 0
    } else {
      em.time_accumulator += em.emission_rate * delta_time
      emit := u32(em.time_accumulator)
      em.time_accumulator -= f32(emit)
      em.pending_emit = emit
    }
    stage_emitter_data(
      &world.staging,
      EmitterHandle{index = u32(idx), generation = entry.generation},
    )
  }
}

// Mutate-and-stage an existing emitter. Only fields with non-nil Maybe values are updated.
set_emitter :: proc(
  w: ^World,
  handle: EmitterHandle,
  texture: Maybe(gpu.Texture2DHandle) = nil,
  enabled: Maybe(bool) = nil,
  emission_rate: Maybe(f32) = nil,
  particle_lifetime: Maybe(f32) = nil,
  size_start: Maybe(f32) = nil,
  size_end: Maybe(f32) = nil,
  weight: Maybe(f32) = nil,
  weight_spread: Maybe(f32) = nil,
  position_spread: Maybe(f32) = nil,
  initial_velocity: Maybe([3]f32) = nil,
  velocity_spread: Maybe(f32) = nil,
  color_start: Maybe([4]f32) = nil,
  color_end: Maybe([4]f32) = nil,
  aabb_min: Maybe([3]f32) = nil,
  aabb_max: Maybe([3]f32) = nil,
) -> bool {
  em, ok := emitter(w, handle)
  if !ok do return false
  if v, has := texture.?;           has do em.texture_handle    = v
  if v, has := enabled.?;           has do em.enabled           = b32(v)
  if v, has := emission_rate.?;     has do em.emission_rate     = v
  if v, has := particle_lifetime.?; has do em.particle_lifetime = v
  if v, has := size_start.?;        has do em.size_start        = v
  if v, has := size_end.?;          has do em.size_end          = v
  if v, has := weight.?;            has do em.weight            = v
  if v, has := weight_spread.?;     has do em.weight_spread     = v
  if v, has := position_spread.?;   has do em.position_spread   = v
  if v, has := initial_velocity.?;  has do em.initial_velocity  = v
  if v, has := velocity_spread.?;   has do em.velocity_spread   = v
  if v, has := color_start.?;       has do em.color_start       = v
  if v, has := color_end.?;         has do em.color_end         = v
  if v, has := aabb_min.?;          has do em.aabb_min          = v
  if v, has := aabb_max.?;          has do em.aabb_max          = v
  stage_emitter_data(&w.staging, handle)
  return true
}

// Spawn a single node carrying an emitter. assign_emitter_to_node binds the
// emitter's sample-position handle to the new node automatically.
spawn_emitter :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  texture: gpu.Texture2DHandle = {},
  emission_rate: f32 = 50.0,
  initial_velocity: [3]f32 = {0, 1, 0},
  velocity_spread: f32 = 0.5,
  color_start: [4]f32 = {1, 1, 1, 1},
  color_end: [4]f32 = {1, 1, 1, 0},
  aabb_min: [3]f32 = {-10, -10, -10},
  aabb_max: [3]f32 = {10, 10, 10},
  particle_lifetime: f32 = 2.0,
  position_spread: f32 = 0.0,
  size_start: f32 = 100.0,
  size_end: f32 = 100.0,
  weight: f32 = 1.0,
  weight_spread: f32 = 0.0,
) -> (node: NodeHandle, emitter_handle: EmitterHandle, ok: bool) {
  emitter_handle = create_emitter(
    world,
    texture_handle    = texture,
    emission_rate     = emission_rate,
    initial_velocity  = initial_velocity,
    velocity_spread   = velocity_spread,
    color_start       = color_start,
    color_end         = color_end,
    aabb_min          = aabb_min,
    aabb_max          = aabb_max,
    particle_lifetime = particle_lifetime,
    position_spread   = position_spread,
    size_start        = size_start,
    size_end          = size_end,
    weight            = weight,
    weight_spread     = weight_spread,
  ) or_return
  node = spawn(world, position, EmitterAttachment{handle = emitter_handle}) or_return
  ok = true
  return
}

// Same as spawn_emitter, but parents the new node under `parent`.
spawn_emitter_child :: proc(
  world: ^World,
  parent: NodeHandle,
  position: [3]f32 = {0, 0, 0},
  texture: gpu.Texture2DHandle = {},
  emission_rate: f32 = 50.0,
  initial_velocity: [3]f32 = {0, 1, 0},
  velocity_spread: f32 = 0.5,
  color_start: [4]f32 = {1, 1, 1, 1},
  color_end: [4]f32 = {1, 1, 1, 0},
  aabb_min: [3]f32 = {-10, -10, -10},
  aabb_max: [3]f32 = {10, 10, 10},
  particle_lifetime: f32 = 2.0,
  position_spread: f32 = 0.0,
  size_start: f32 = 100.0,
  size_end: f32 = 100.0,
  weight: f32 = 1.0,
  weight_spread: f32 = 0.0,
) -> (node: NodeHandle, emitter_handle: EmitterHandle, ok: bool) {
  emitter_handle = create_emitter(
    world,
    texture_handle    = texture,
    emission_rate     = emission_rate,
    initial_velocity  = initial_velocity,
    velocity_spread   = velocity_spread,
    color_start       = color_start,
    color_end         = color_end,
    aabb_min          = aabb_min,
    aabb_max          = aabb_max,
    particle_lifetime = particle_lifetime,
    position_spread   = position_spread,
    size_start        = size_start,
    size_end          = size_end,
    weight            = weight,
    weight_spread     = weight_spread,
  ) or_return
  node = spawn_child(world, parent, position, EmitterAttachment{handle = emitter_handle}) or_return
  ok = true
  return
}
