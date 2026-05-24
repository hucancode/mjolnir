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
  _, freed := cont.free(&world.emitters, handle)
  return freed
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
