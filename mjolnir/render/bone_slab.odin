package render

import cont "../containers"

ensure_bone_matrix_range_for_node :: proc(
  render: ^Manager,
  handle: u32,
  bone_count: u32,
) -> u32 {
  if existing, ok := render.internal.bone_matrix_offsets[handle]; ok {
    return existing
  }
  offset := cont.slab_alloc(&render.internal.bone_matrix_slab, bone_count)
  if offset == 0xFFFFFFFF do return 0xFFFFFFFF
  render.internal.bone_matrix_offsets[handle] = offset
  return offset
}

release_bone_matrix_range_for_node :: proc(render: ^Manager, handle: u32) {
  if offset, ok := render.internal.bone_matrix_offsets[handle]; ok {
    cont.slab_free(&render.internal.bone_matrix_slab, offset)
    delete_key(&render.internal.bone_matrix_offsets, handle)
  }
}
