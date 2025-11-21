package resources

import cont "../containers"
import "../geometry"
import "../gpu"

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

// Upload node transform matrix to GPU
node_upload_transform :: proc(
  rm: ^Manager,
  node_handle: NodeHandle,
  world_matrix: ^matrix[4, 4]f32,
) {
  gpu.write(&rm.world_matrix_buffer.buffer, world_matrix, int(node_handle.index))
}

// Upload node data to GPU
node_upload_data :: proc(rm: ^Manager, node_handle: NodeHandle, data: ^NodeData) {
  gpu.write(&rm.node_data_buffer.buffer, data, int(node_handle.index))
}
