package resources

import "../animation"
import "core:log"
import "core:math/linalg"
import "../geometry"
import "../gpu"
import vk "vendor:vulkan"

Bone :: struct {
  children:            []u32,
  inverse_bind_matrix: matrix[4, 4]f32,
  name:                string,
}

bone_destroy :: proc(bone: ^Bone) {
  delete(bone.children)
  bone.children = nil
}

MAX_MESHES :: 65536

MeshFlag :: enum u32 {
  SKINNED,
}

MeshFlagSet :: bit_set[MeshFlag; u32]

MeshData :: struct {
  aabb_min:              [3]f32,
  index_count:           u32,
  aabb_max:              [3]f32,
  first_index:           u32,
  vertex_offset:         i32,
  vertex_skinning_offset: u32,
  flags:                 MeshFlagSet,
  _padding:              u32,
}

Skinning :: struct {
  root_bone_index:            u32,
  bones:                      []Bone,
  vertex_skinning_allocation: BufferAllocation,
}

Mesh :: struct {
  using data:        MeshData,
  vertex_allocation: BufferAllocation,
  index_allocation:  BufferAllocation,
  skinning:          Maybe(Skinning),
}

mesh_destroy :: proc(
  self: ^Mesh,
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  manager_free_vertices(manager, self.vertex_allocation)
  manager_free_indices(manager, self.index_allocation)
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  manager_free_vertex_skinning(manager, skin.vertex_skinning_allocation)
  for &bone in skin.bones do bone_destroy(&bone)
  delete(skin.bones)
}

find_bone_by_name :: proc(mesh: ^Mesh, name: string) -> (index: u32, ok: bool) #optional_ok {
  skin, has_skin := &mesh.skinning.?
  if !has_skin do return
  for bone, i in skin.bones {
    if bone.name == name {
      return u32(i), true
    }
  }
  return 0, false
}

mesh_init :: proc(
  self: ^Mesh,
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> vk.Result {
  defer geometry.delete_geometry(data)
  self.aabb_min = data.aabb.min
  self.aabb_max = data.aabb.max
  self.vertex_allocation = manager_allocate_vertices(
    manager,
    gpu_context,
    data.vertices,
  ) or_return
  self.index_allocation = manager_allocate_indices(
    manager,
    gpu_context,
    data.indices,
  ) or_return
  if len(data.skinnings) <= 0 {
    return .SUCCESS
  }
  allocation, ret := manager_allocate_vertex_skinning(
    manager,
    gpu_context,
    data.skinnings,
  )
  if ret != .SUCCESS {
    return ret
  }
  self.skinning = Skinning {
    bones                      = make([]Bone, 0),
    vertex_skinning_allocation = allocation,
  }
  return .SUCCESS
}

make_animation_instance :: proc(
  manager: ^Manager,
  animation_name: string,
  mode: animation.PlayMode,
  speed: f32 = 1.0,
) -> (
  instance: animation.Instance,
  ok: bool,
) #optional_ok {
  // TODO: use linear search as a first working implementation
  // later we need to do better than this linear search
  for &entry in manager.animation_clips.entries do if entry.active {
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

create_mesh :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  mesh: ^Mesh,
  ret: vk.Result,
) {
  handle, mesh = alloc(&manager.meshes)
  ret = mesh_init(mesh, gpu_context, manager, data)
  if ret != .SUCCESS {
    return
  }
  ret = mesh_write_to_gpu(manager, handle, mesh)
  return
}

create_mesh_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_mesh(gpu_context, manager, data)
  return h, ret == .SUCCESS
}

mesh_update_gpu_data :: proc(mesh: ^Mesh) {
  mesh.index_count = mesh.index_allocation.count
  mesh.first_index = mesh.index_allocation.offset
  mesh.vertex_offset = cast(i32)mesh.vertex_allocation.offset
  mesh.flags = {}
  skin, has_skin := mesh.skinning.?
  if has_skin && skin.vertex_skinning_allocation.count > 0 {
    mesh.flags |= {.SKINNED}
    mesh.vertex_skinning_offset = skin.vertex_skinning_allocation.offset
  }
}

mesh_write_to_gpu :: proc(
  manager: ^Manager,
  handle: Handle,
  mesh: ^Mesh,
) -> vk.Result {
  if handle.index >= MAX_MESHES {
    log.errorf("Mesh index %d exceeds capacity %d", handle.index, MAX_MESHES)
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  mesh_update_gpu_data(mesh)
  return gpu.write(
    &manager.mesh_data_buffer,
    &mesh.data,
    int(handle.index),
  )
}
