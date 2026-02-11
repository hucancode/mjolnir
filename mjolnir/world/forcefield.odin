package world

import cont "../containers"

ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  node_handle: NodeHandle,
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
  return handle, true
}

destroy_forcefield :: proc(world: ^World, handle: ForceFieldHandle) -> bool {
  _, freed := cont.free(&world.forcefields, handle)
  return freed
}
