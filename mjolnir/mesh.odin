package mjolnir

import "animation"
import "core:log"
import "core:math/linalg"
import "geometry"
import "gpu"
import vk "vendor:vulkan"

Bone :: struct {
  children:            []u32,
  inverse_bind_matrix: matrix[4, 4]f32,
  name:                string,
}

bone_deinit :: proc(bone: ^Bone) {
  delete(bone.children)
  bone.children = nil
}

Skinning :: struct {
  root_bone_index: u32,
  bones:           []Bone,
  skin_buffer:     gpu.DataBuffer(geometry.SkinningData),
}

Mesh :: struct {
  vertex_allocation: BufferAllocation,
  index_allocation:  BufferAllocation,
  aabb:              geometry.Aabb,
  skinning:          Maybe(Skinning),
}

mesh_deinit :: proc(
  self: ^Mesh,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  warehouse_free_vertices(warehouse, self.vertex_allocation)
  warehouse_free_indices(warehouse, self.index_allocation)
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  gpu.data_buffer_deinit(gpu_context, &skin.skin_buffer)
  for &bone in skin.bones do bone_deinit(&bone)
  delete(skin.bones)
}

mesh_init :: proc(
  self: ^Mesh,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  data: geometry.Geometry,
) -> vk.Result {
  defer geometry.delete_geometry(data)
  self.aabb = data.aabb
  self.vertex_allocation = warehouse_allocate_vertices(
    warehouse,
    data.vertices,
  ) or_return
  self.index_allocation = warehouse_allocate_indices(
    warehouse,
    data.indices,
  ) or_return
  if len(data.skinnings) <= 0 {
    return .SUCCESS
  }
  log.info("creating skin buffer", len(data.skinnings))
  skin_buffer := gpu.create_local_buffer(
    gpu_context,
    geometry.SkinningData,
    len(data.skinnings),
    {.VERTEX_BUFFER},
    raw_data(data.skinnings),
  ) or_return
  self.skinning = Skinning {
    bones       = make([]Bone, 0),
    skin_buffer = skin_buffer,
  }
  return .SUCCESS
}

make_animation_instance :: proc(
  warehouse: ^ResourceWarehouse,
  animation_name: string,
  mode: animation.PlayMode,
  speed: f32 = 1.0,
) -> (
  instance: animation.Instance,
  ok: bool,
) #optional_ok {
  // TODO: use linear search as a first working implementation
  // later we need to do better than this linear search
  for &entry in warehouse.animation_clips.entries {
    if !entry.active do continue
    clip := &entry.item
    if clip.name != animation_name do continue
    instance = {
      clip     = clip,
      mode     = mode,
      status   = .PLAYING,
      time     = 0.0,
      duration = clip.duration,
      speed    = speed,
    }
    ok = true
    break
  }
  return
}

sample_clip :: proc(
  self: ^Mesh,
  clip: ^animation.Clip,
  t: f32,
  out_bone_matrices: []matrix[4, 4]f32,
) {
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  if len(out_bone_matrices) < len(skin.bones) {
    return
  }
  if clip == nil do return

  TraverseEntry :: struct {
    transform: matrix[4, 4]f32,
    bone:      u32,
  }
  stack := make(
    [dynamic]TraverseEntry,
    0,
    len(skin.bones),
    context.temp_allocator,
  )
  append(
    &stack,
    TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
  )
  for len(stack) > 0 {
    entry := pop(&stack)
    bone := &skin.bones[entry.bone]
    local_transform: geometry.Transform
    if entry.bone < u32(len(clip.channels)) {
      local_transform.position, local_transform.rotation, local_transform.scale =
        animation.channel_sample(clip.channels[entry.bone], t)
    }
    local_matrix := linalg.matrix4_from_trs(
      local_transform.position,
      local_transform.rotation,
      local_transform.scale,
    )
    world_transform := entry.transform * local_matrix
    out_bone_matrices[entry.bone] = world_transform * bone.inverse_bind_matrix
    for child_index in bone.children do append(&stack, TraverseEntry{world_transform, child_index})
  }
}
