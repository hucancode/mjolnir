package resources

import cont "../containers"
import "../gpu"
import vk "vendor:vulkan"

EmitterData :: struct {
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
  time_accumulator:  f32,
  size_end:          f32,
  weight:            f32,
  weight_spread:     f32,
  texture_index:     u32,
  node_index:        u32,
}

Emitter :: struct {
  using data:     EmitterData,
  enabled:        b32,
  texture_handle: Handle,
  node_handle:    Handle,
}

create_emitter :: proc(
  rm: ^Manager,
  node_handle: Handle,
  texture_handle: Handle,
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
  ret: Handle,
  ok: bool,
) #optional_ok {
  handle, emitter := cont.alloc(&rm.emitters) or_return
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
  emitter_write_to_gpu(rm, handle, emitter, false)
  return handle, true
}

destroy_emitter_handle :: proc(manager: ^Manager, handle: Handle) -> bool {
  _, freed := cont.free(&manager.emitters, handle)
  return freed
}

emitter_update_gpu_data :: proc(
  emitter: ^Emitter,
  time_accumulator: f32 = 0.0,
) {
  emitter.time_accumulator = time_accumulator
  emitter.texture_index = emitter.texture_handle.index
  emitter.node_index = emitter.node_handle.index
}

emitter_write_to_gpu :: proc(
  rm: ^Manager,
  handle: Handle,
  emitter: ^Emitter,
  preserve_time_accumulator: bool = true,
) -> vk.Result {
  if handle.index >= MAX_EMITTERS {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  time_acc: f32 = 0.0
  if preserve_time_accumulator {
    existing := gpu.get(&rm.emitter_buffer.buffer, handle.index)
    time_acc = existing.time_accumulator
  }
  emitter_update_gpu_data(emitter, time_acc)
  gpu.write(
    &rm.emitter_buffer.buffer,
    &emitter.data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}
