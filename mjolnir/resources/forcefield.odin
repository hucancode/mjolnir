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
  node_handle: NodeHandle,
}

create_forcefield :: proc(
  rm: ^Manager,
  node_handle: NodeHandle,
  area_of_effect: f32,
  strength: f32,
  tangent_strength: f32,
) -> (
  ret: ForceFieldHandle,
  ok: bool,
) #optional_ok {
  handle, forcefield := cont.alloc(&rm.forcefields, ForceFieldHandle) or_return
  forcefield.tangent_strength = tangent_strength
  forcefield.strength = strength
  forcefield.area_of_effect = area_of_effect
  forcefield.node_handle = node_handle
  forcefield_write_to_gpu(rm, handle, forcefield)
  return handle, true
}

destroy_forcefield :: proc(rm: ^Manager, handle: ForceFieldHandle) -> bool {
  _, freed := cont.free(&rm.forcefields, handle)
  return freed
}

forcefield_update_gpu_data :: proc(ff: ^ForceField) {
  ff.node_index = ff.node_handle.index
}

forcefield_write_to_gpu :: proc(
  rm: ^Manager,
  handle: ForceFieldHandle,
  ff: ^ForceField,
) -> vk.Result {
  forcefield_update_gpu_data(ff)
  gpu.write(
    &rm.forcefield_buffer.buffer,
    &ff.data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}
