package data

NodeFlag :: enum u32 {
	VISIBLE,
	CULLING_ENABLED,
	MATERIAL_TRANSPARENT,
	MATERIAL_WIREFRAME,
	MATERIAL_SPRITE,
	CASTS_SHADOW,
	NAVIGATION_OBSTACLE,
}

NodeFlagSet :: bit_set[NodeFlag;u32]

NodeData :: struct {
	material_id:           u32,
	mesh_id:               u32,
	attachment_data_index: u32, // For skinned meshes: bone matrix buffer offset; For sprites: sprite index
	flags:                 NodeFlagSet,
}
