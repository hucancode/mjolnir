package data

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