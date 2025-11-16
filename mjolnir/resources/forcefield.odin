package resources

import cont "../containers"
import "../gpu"
import vk "vendor:vulkan"

ForceFieldData :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  node_index:       u32,
}

ForceField :: struct {
  using data:  ForceFieldData,
  node_handle: Handle,
}

create_forcefield :: proc(
  manager: ^Manager,
  node_handle: Handle,
  area_of_effect: f32,
  strength: f32,
  tangent_strength: f32,
) -> (
  ret: Handle,
  ok: bool,
) #optional_ok {
  handle, forcefield := cont.alloc(&manager.forcefields) or_return
  forcefield.tangent_strength = tangent_strength
  forcefield.strength = strength
  forcefield.area_of_effect = area_of_effect
  forcefield.node_handle = node_handle
  forcefield_write_to_gpu(manager, handle, forcefield)
  return handle, true
}

destroy_forcefield_handle :: proc(manager: ^Manager, handle: Handle) -> bool {
  _, freed := cont.free(&manager.forcefields, handle)
  return freed
}

forcefield_update_gpu_data :: proc(ff: ^ForceField) {
  ff.node_index = ff.node_handle.index
}

forcefield_write_to_gpu :: proc(
  manager: ^Manager,
  handle: Handle,
  ff: ^ForceField,
) -> vk.Result {
  forcefield_update_gpu_data(ff)
  gpu.write(
    &manager.forcefield_buffer.buffer,
    &ff.data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}
