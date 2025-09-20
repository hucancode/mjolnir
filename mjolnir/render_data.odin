package mjolnir

NodeGPUFlags :: bit_set[NodeGPUFlag; u32]

NodeGPUFlag :: enum u32 {
  ACTIVE,
  HAS_MESH,
  SKINNED,
  CAST_SHADOW,
}

NodeGPUData :: struct {
  vertex_offset:      u32,
  index_offset:       u32,
  index_count:        u32,
  material_index:     u32,
  skin_vertex_offset: u32,
  bone_matrix_offset: u32,
  flags:              NodeGPUFlags,
  padding:            u32,
}

MaterialGPUData :: struct {
  base_color_factor:       [4]f32,
  albedo_texture_index:    u32,
  metallic_texture_index:  u32,
  normal_texture_index:    u32,
  emissive_texture_index:  u32,
  occlusion_texture_index: u32,
  material_type:           u32,
  features_mask:           u32,
  metallic_value:          f32,
  roughness_value:         f32,
  emissive_value:          f32,
  padding:                 f32,
}
