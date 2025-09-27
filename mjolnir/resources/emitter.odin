package resources

import "../geometry"
import "../gpu"

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
  aabb_min:          [4]f32,
  aabb_max:          [4]f32,
}

Emitter :: struct {
  initial_velocity:  [4]f32,
  color_start:       [4]f32,
  color_end:         [4]f32,
  emission_rate:     f32,
  particle_lifetime: f32,
  position_spread:   f32,
  velocity_spread:   f32,
  size_start:        f32,
  size_end:          f32,
  enabled:           b32,
  weight:            f32,
  weight_spread:     f32,
  texture_handle:    Handle,
  bounding_box:      geometry.Aabb,
  node_handle:       Handle,
}

update_emitter_gpu_data :: proc(
  manager: ^Manager,
  handle: Handle,
  node_index: u32,
  visible: bool,
) {
  if handle.index >= MAX_EMITTERS {
    return
  }

  emitter := get(manager.emitters, handle)
  if emitter == nil {
    return
  }

  gpu_data := EmitterData {
    initial_velocity  = emitter.initial_velocity,
    color_start       = emitter.color_start,
    color_end         = emitter.color_end,
    emission_rate     = emitter.emission_rate,
    particle_lifetime = emitter.particle_lifetime,
    position_spread   = emitter.position_spread,
    velocity_spread   = emitter.velocity_spread,
    size_start        = emitter.size_start,
    size_end          = emitter.size_end,
    weight            = emitter.weight,
    weight_spread     = emitter.weight_spread,
    texture_index     = emitter.texture_handle.index,
    node_index        = node_index,
    visible           = cast(b32)(visible && emitter.enabled != b32(false)),
    aabb_min          = {
      emitter.bounding_box.min.x,
      emitter.bounding_box.min.y,
      emitter.bounding_box.min.z,
      0.0,
    },
    aabb_max          = {
      emitter.bounding_box.max.x,
      emitter.bounding_box.max.y,
      emitter.bounding_box.max.z,
      0.0,
    },
  }

  current := gpu.staged_buffer_get(&manager.emitter_buffer, handle.index)
  if current != nil {
    gpu_data.time_accumulator = current.time_accumulator
  }

  gpu.staged_buffer_write(
    &manager.emitter_buffer,
    &gpu_data,
    int(handle.index),
  )
}
