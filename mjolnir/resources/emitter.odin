package resources

import cont "../containers"
import "../gpu"
import vk "vendor:vulkan"

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
  padding1:          f32,
  aabb_max:          [3]f32,
  padding2:          f32,
}

Emitter :: struct {
  using data:     EmitterData,
  enabled:        b32,
  texture_handle: Handle,
  node_handle:    Handle,
}

create_emitter_handle :: proc(
  manager: ^Manager,
  node_handle: Handle,
  config: Emitter,
) -> (
  ret: Handle,
  ok: bool,
) {
  handle, emitter := cont.alloc(&manager.emitters) or_return
  emitter^ = config
  emitter.node_handle = node_handle
  emitter_write_to_gpu(manager, handle, emitter, false)
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
  emitter.visible = b32(true)
}

emitter_write_to_gpu :: proc(
  manager: ^Manager,
  handle: Handle,
  emitter: ^Emitter,
  preserve_time_accumulator: bool = true,
) -> vk.Result {
  if handle.index >= MAX_EMITTERS {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  time_acc: f32 = 0.0
  if preserve_time_accumulator {
    existing := gpu.mutable_buffer_get(&manager.emitter_buffer, handle.index)
    time_acc = existing.time_accumulator
  }
  emitter_update_gpu_data(emitter, time_acc)
  gpu.write(
    &manager.emitter_buffer,
    &emitter.data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}
