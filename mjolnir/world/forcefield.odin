package world

import cont "../containers"

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

forcefield_update_gpu_data :: proc(ff: ^ForceField) {
  ff.node_index = ff.node_handle.index
}

create_forcefield :: proc(
  world: ^World,
  node_handle: NodeHandle,
  area_of_effect: f32,
  strength: f32,
  tangent_strength: f32,
) -> (
  ret: ForceFieldHandle,
  ok: bool,
) #optional_ok {
  handle, forcefield := cont.alloc(&world.forcefields, ForceFieldHandle) or_return
  forcefield.tangent_strength = tangent_strength
  forcefield.strength = strength
  forcefield.area_of_effect = area_of_effect
  forcefield.node_handle = node_handle
  forcefield_update_gpu_data(forcefield)
  return handle, true
}

destroy_forcefield :: proc(world: ^World, handle: ForceFieldHandle) -> bool {
  _, freed := cont.free(&world.forcefields, handle)
  return freed
}
