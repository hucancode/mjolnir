package resources

import "../geometry"

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