package world

import cont "../containers"

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
  enabled:           b32,
  texture_handle:    Image2DHandle,
  node_handle:       NodeHandle,
}

create_emitter :: proc(
  world: ^World,
  node_handle: NodeHandle,
  texture_handle: Image2DHandle,
  emission_rate: f32,
  initial_velocity: [3]f32,
  velocity_spread: f32,
  color_start: [4]f32,
  color_end: [4]f32,
  aabb_min: [3]f32,
  aabb_max: [3]f32,
  particle_lifetime: f32,
  position_spread: f32,
  size_start: f32,
  size_end: f32,
  weight: f32,
  weight_spread: f32,
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
  return handle, true
}

destroy_emitter :: proc(world: ^World, handle: EmitterHandle) -> bool {
  _, freed := cont.free(&world.emitters, handle)
  return freed
}
