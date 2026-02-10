package world

import cont "../containers"
import d "../data"

ForceFieldData :: d.ForceFieldData
ForceField :: d.ForceField
forcefield_update_gpu_data :: d.forcefield_update_gpu_data

create_forcefield :: proc(
  world: ^World,
  node_handle: d.NodeHandle,
  area_of_effect: f32,
  strength: f32,
  tangent_strength: f32,
) -> (
  ret: d.ForceFieldHandle,
  ok: bool,
) #optional_ok {
  handle, forcefield := cont.alloc(&world.forcefields, d.ForceFieldHandle) or_return
  forcefield.tangent_strength = tangent_strength
  forcefield.strength = strength
  forcefield.area_of_effect = area_of_effect
  forcefield.node_handle = node_handle
  forcefield_update_gpu_data(forcefield)
  return handle, true
}

destroy_forcefield :: proc(world: ^World, handle: d.ForceFieldHandle) -> bool {
  _, freed := cont.free(&world.forcefields, handle)
  return freed
}
