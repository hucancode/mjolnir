package resources

import vk "vendor:vulkan"
import "../geometry"
import "../gpu"

ForceFieldData :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  fade:             f32,
  node_index:       u32,
  visible:          b32,
  _padding:         [2]u32,
}

ForceField :: struct {
  using data:  ForceFieldData,
  node_handle: Handle,
}

create_forcefield_handle :: proc(
  manager: ^Manager,
  node_handle: Handle,
  config: ForceField,
) -> Handle {
  handle, forcefield := alloc(&manager.forcefields)
  forcefield^ = config
  forcefield.node_handle = node_handle
  forcefield_write_to_gpu(manager, handle, forcefield)
  return handle
}

destroy_forcefield_handle :: proc(
  manager: ^Manager,
  handle: Handle,
) -> bool {
  _, freed := free(&manager.forcefields, handle)
  return freed
}

forcefield_update_gpu_data :: proc(ff: ^ForceField) {
  ff.node_index = ff.node_handle.index
  ff.visible = b32(true)
}

forcefield_write_to_gpu :: proc(
  manager: ^Manager,
  handle: Handle,
  ff: ^ForceField,
) -> vk.Result {
  if handle.index >= MAX_FORCE_FIELDS {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  forcefield_update_gpu_data(ff)
  gpu.write(
    &manager.forcefield_buffer,
    &ff.data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}
