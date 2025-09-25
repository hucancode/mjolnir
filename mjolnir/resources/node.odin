package resources

NodeFlag :: enum u32 {
  VISIBLE,
  CULLING_ENABLED,
  MATERIAL_TRANSPARENT,
  MATERIAL_WIREFRAME,
  CASTS_SHADOW,
}

NodeFlagSet :: bit_set[NodeFlag; u32]

NodeData :: struct {
  material_id:        u32,
  mesh_id:            u32,
  bone_matrix_offset: u32,
  flags:              NodeFlagSet,
}
