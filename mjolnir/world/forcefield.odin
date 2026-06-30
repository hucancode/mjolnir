package world

import cont "../containers"

ForceField :: struct {
  tangent_strength: f32,
  strength:         f32,
  area_of_effect:   f32,
  node_handle:      NodeHandle,
  enabled:          b32,
}

create_forcefield :: proc(
  world: ^World,
  node_handle: NodeHandle = {},
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (
  ret: ForceFieldHandle,
  ok: bool,
) #optional_ok {
  handle, forcefield := cont.alloc(
    &world.forcefields,
    ForceFieldHandle,
  ) or_return
  forcefield.tangent_strength = tangent_strength
  forcefield.strength = strength
  forcefield.area_of_effect = area_of_effect
  forcefield.node_handle = node_handle
  forcefield.enabled = true
  stage_forcefield_data(&world.staging, handle)
  return handle, true
}

destroy_forcefield :: proc(world: ^World, handle: ForceFieldHandle) -> bool {
  return cont.free_deferred(&world.forcefields, handle)
}

// Mutate-and-stage an existing forcefield. `enabled` toggles without losing config.
set_forcefield :: proc(
  w: ^World,
  handle: ForceFieldHandle,
  strength: Maybe(f32) = nil,
  tangent_strength: Maybe(f32) = nil,
  area_of_effect: Maybe(f32) = nil,
  enabled: Maybe(bool) = nil,
) -> bool {
  ff, ok := forcefield(w, handle)
  if !ok do return false
  if v, has := strength.?;         has do ff.strength         = v
  if v, has := tangent_strength.?; has do ff.tangent_strength = v
  if v, has := area_of_effect.?;   has do ff.area_of_effect   = v
  if v, has := enabled.?;          has do ff.enabled          = b32(v)
  stage_forcefield_data(&w.staging, handle)
  return true
}

// Spawn a single node carrying a force field. assign_forcefield_to_node binds
// the field's sample-position handle to the new node automatically.
spawn_forcefield :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (node: NodeHandle, ff: ForceFieldHandle, ok: bool) {
  ff = create_forcefield(
    world,
    node_handle      = {},
    area_of_effect   = area_of_effect,
    strength         = strength,
    tangent_strength = tangent_strength,
  ) or_return
  node = spawn(world, position, ForceFieldAttachment{handle = ff}) or_return
  ok = true
  return
}

// Same as spawn_forcefield, but parents the new node under `parent`.
spawn_forcefield_child :: proc(
  world: ^World,
  parent: NodeHandle,
  position: [3]f32 = {0, 0, 0},
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (node: NodeHandle, ff: ForceFieldHandle, ok: bool) {
  ff = create_forcefield(
    world,
    node_handle      = {},
    area_of_effect   = area_of_effect,
    strength         = strength,
    tangent_strength = tangent_strength,
  ) or_return
  node = spawn_child(world, parent, position, ForceFieldAttachment{handle = ff}) or_return
  ok = true
  return
}
