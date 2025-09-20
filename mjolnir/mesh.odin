package mjolnir

import "animation"
import "core:log"
import "core:math/linalg"
import "geometry"
import "gpu"
import "resource"
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

// Skeleton metadata (bone hierarchy) - CPU-only, for animation system
Skeleton :: struct {
  root_bone_index: u32,
  bones:           []Bone,  // Bone hierarchy and names
}

skeleton_deinit :: proc(skeleton: ^Skeleton) {
  for &bone in skeleton.bones do bone_deinit(&bone)
  delete(skeleton.bones)
}

// Updated mesh structure for bindless/indirect rendering
Mesh :: struct {
  // Buffer allocations for rendering
  vertex_allocation:           BufferAllocation,  // Offset+count in global vertex buffer
  index_allocation:            BufferAllocation,  // Offset+count in global index buffer
  vertex_skinning_allocation:  BufferAllocation,  // Offset+count in global vertex skinning buffer (if skinned)

  // Cached metadata for CPU operations (avoid GPU buffer reads)
  aabb:                        geometry.Aabb,     // Local copy for CPU culling/queries
  is_skinned:                  b32,               // Quick check without GPU buffer access

  // Animation system reference (CPU-only)
  skeleton_handle:             Handle, // Reference to bone hierarchy (if skinned)
}

mesh_deinit :: proc(
  self: ^Mesh,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  warehouse_free_vertices(warehouse, self.vertex_allocation)
  warehouse_free_indices(warehouse, self.index_allocation)
  if self.is_skinned {
    warehouse_free_vertex_skinning_data(warehouse, self.vertex_skinning_allocation)
  }
}

mesh_init :: proc(
  self: ^Mesh,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  data: geometry.Geometry,
  mesh_id: u32,
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
  if len(data.skinnings) > 0 {
    self.vertex_skinning_allocation = warehouse_allocate_vertex_skinning_data(
      warehouse,
      data.skinnings,
    ) or_return
    self.is_skinned = true
  } else {
    self.is_skinned = false
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
  warehouse: ^ResourceWarehouse,
  skeleton_handle: Handle,
  clip: ^animation.Clip,
  t: f32,
  out_bone_matrices: []matrix[4, 4]f32,
) {
  skeleton := resource.get(warehouse.skeletons, skeleton_handle)
  if skeleton == nil do return
  if len(out_bone_matrices) < len(skeleton.bones) {
    return
  }
  if clip == nil do return

  TraverseEntry :: struct {
    transform: matrix[4, 4]f32,
    bone:      u32,
  }
  stack := make([dynamic]TraverseEntry, context.temp_allocator)
  append(
    &stack,
    TraverseEntry{linalg.MATRIX4F32_IDENTITY, skeleton.root_bone_index},
  )
  for len(stack) > 0 {
    entry := pop(&stack)
    bone := &skeleton.bones[entry.bone]
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
