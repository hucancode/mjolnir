package resources

import "../animation"
import "../geometry"
import "../gpu"
import "core:log"
import "core:math/linalg"
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

MeshFlagSet :: bit_set[MeshFlag;u32]

MeshData :: struct {
  aabb_min:               [3]f32,
  index_count:            u32,
  aabb_max:               [3]f32,
  first_index:            u32,
  vertex_offset:          i32,
  vertex_skinning_offset: u32,
  flags:                  MeshFlagSet,
  _padding:               u32,
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

mesh_destroy :: proc(self: ^Mesh, gctx: ^gpu.GPUContext, manager: ^Manager) {
  manager_free_vertices(manager, self.vertex_allocation)
  manager_free_indices(manager, self.index_allocation)
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  manager_free_vertex_skinning(manager, skin.vertex_skinning_allocation)
  for &bone in skin.bones do bone_destroy(&bone)
  delete(skin.bones)
}

find_bone_by_name :: proc(
  mesh: ^Mesh,
  name: string,
) -> (
  index: u32,
  ok: bool,
) #optional_ok {
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
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> vk.Result {
  defer geometry.delete_geometry(data)
  self.aabb_min = data.aabb.min
  self.aabb_max = data.aabb.max
  self.vertex_allocation = manager_allocate_vertices(
    manager,
    gctx,
    data.vertices,
  ) or_return
  self.index_allocation = manager_allocate_indices(
    manager,
    gctx,
    data.indices,
  ) or_return
  if len(data.skinnings) <= 0 {
    return .SUCCESS
  }
  allocation, ret := manager_allocate_vertex_skinning(
    manager,
    gctx,
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

// Sample animation clip with IK corrections applied
// This version first computes FK, then applies IK targets, then outputs skinning matrices
sample_clip_with_ik :: proc(
  self: ^Mesh,
  clip: ^animation.Clip,
  t: f32,
  ik_targets: []animation.TwoBoneIKTarget,
  out_bone_matrices: []matrix[4, 4]f32,
) {
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  if len(out_bone_matrices) < len(skin.bones) {
    return
  }
  if clip == nil do return

  bone_count := len(skin.bones)

  // Allocate temporary storage for world transforms
  world_transforms := make(
    []animation.BoneTransform,
    bone_count,
    context.temp_allocator,
  )

  // Phase 1: FK pass - compute world transforms from animation
  TraverseEntry :: struct {
    parent_world: matrix[4, 4]f32,
    bone_index:   u32,
  }
  stack := make(
    [dynamic]TraverseEntry,
    0,
    bone_count,
    context.temp_allocator,
  )
  append(
    &stack,
    TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
  )

  for len(stack) > 0 {
    entry := pop(&stack)
    bone := &skin.bones[entry.bone_index]
    bone_idx := entry.bone_index

    // Sample animation for local transform
    local_transform: geometry.Transform
    if bone_idx < u32(len(clip.channels)) {
      local_transform.position, local_transform.rotation, local_transform.scale =
        animation.channel_sample(clip.channels[bone_idx], t)
    } else {
      local_transform.scale = [3]f32{1, 1, 1}
      local_transform.rotation = linalg.QUATERNIONF32_IDENTITY
    }

    local_matrix := linalg.matrix4_from_trs(
      local_transform.position,
      local_transform.rotation,
      local_transform.scale,
    )

    // Compute world transform
    world_matrix := entry.parent_world * local_matrix

    // Store world transform
    world_transforms[bone_idx].world_matrix = world_matrix
    world_transforms[bone_idx].world_position = animation.matrix_get_position(
      world_matrix,
    )
    world_transforms[bone_idx].world_rotation = animation.matrix_get_rotation(
      world_matrix,
    )

    // Push children
    for child_idx in bone.children {
      append(&stack, TraverseEntry{world_matrix, child_idx})
    }
  }

  // Phase 2: Apply IK corrections
  for target in ik_targets {
    if !target.enabled do continue

    // Compute bone lengths (could be cached per mesh)
    root_pos := world_transforms[target.root_bone_idx].world_position
    mid_pos := world_transforms[target.middle_bone_idx].world_position
    end_pos := world_transforms[target.end_bone_idx].world_position

    upper_length := linalg.distance(root_pos, mid_pos)
    lower_length := linalg.distance(mid_pos, end_pos)
    bone_lengths := [2]f32{upper_length, lower_length}

    // Apply IK
    animation.two_bone_ik_solve(world_transforms[:], target, bone_lengths)
  }

  // Phase 2.5: Update child bones after IK modifications
  // After IK modifies parent bones, we need to recompute world transforms for their children
  // to maintain hierarchical consistency
  if len(ik_targets) > 0 {
    // Collect all bones affected by IK (root, middle, end from all targets)
    affected_bones := make(map[u32]bool, len(ik_targets) * 3, context.temp_allocator)
    for target in ik_targets {
      if !target.enabled do continue
      affected_bones[target.root_bone_idx] = true
      affected_bones[target.middle_bone_idx] = true
      affected_bones[target.end_bone_idx] = true
    }

    // Recompute world transforms for children of affected bones
    update_stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)

    // Find all children of affected bones and queue them for update
    for bone_idx in affected_bones {
      bone := &skin.bones[bone_idx]
      parent_world := world_transforms[bone_idx].world_matrix

      for child_idx in bone.children {
        // Skip if this child is also an IK-affected bone (already updated by IK)
        if child_idx in affected_bones do continue

        append(&update_stack, TraverseEntry{parent_world, child_idx})
      }
    }

    // Traverse and update child bones hierarchically
    for len(update_stack) > 0 {
      entry := pop(&update_stack)
      bone := &skin.bones[entry.bone_index]
      bone_idx := entry.bone_index

      // Get the local transform from the animation (FK)
      // We keep the animated local transform, only updating world space
      local_transform: geometry.Transform
      if bone_idx < u32(len(clip.channels)) {
        local_transform.position, local_transform.rotation, local_transform.scale =
          animation.channel_sample(clip.channels[bone_idx], t)
      } else {
        local_transform.scale = [3]f32{1, 1, 1}
        local_transform.rotation = linalg.QUATERNIONF32_IDENTITY
      }

      local_matrix := linalg.matrix4_from_trs(
        local_transform.position,
        local_transform.rotation,
        local_transform.scale,
      )

      // Recompute world transform using IK-modified parent
      world_matrix := entry.parent_world * local_matrix

      // Update world transform
      world_transforms[bone_idx].world_matrix = world_matrix
      world_transforms[bone_idx].world_position = animation.matrix_get_position(
        world_matrix,
      )
      world_transforms[bone_idx].world_rotation = animation.matrix_get_rotation(
        world_matrix,
      )

      // Queue children for update
      for child_idx in bone.children {
        append(&update_stack, TraverseEntry{world_matrix, child_idx})
      }
    }
  }

  // Phase 3: Compute final skinning matrices = world * inverse_bind
  for i in 0 ..< bone_count {
    world_matrix := world_transforms[i].world_matrix
    out_bone_matrices[i] = world_matrix * skin.bones[i].inverse_bind_matrix
  }
}

create_mesh :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  mesh: ^Mesh,
  ret: vk.Result,
) {
  ok: bool
  handle, mesh, ok = alloc(&manager.meshes)
  if !ok {
    log.error("Failed to allocate mesh: pool capacity reached")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  ret = mesh_init(mesh, gctx, manager, data)
  if ret != .SUCCESS {
    return
  }
  ret = mesh_write_to_gpu(manager, handle, mesh)
  return
}

create_mesh_handle :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_mesh(gctx, manager, data)
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
  return gpu.write(&manager.mesh_data_buffer, &mesh.data, int(handle.index))
}
