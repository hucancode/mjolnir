package resources

import "../animation"
import cont "../containers"
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
  bone_lengths:               []f32, // Length from parent to this bone
}

Mesh :: struct {
  using data:        MeshData,
  vertex_allocation: BufferAllocation,
  index_allocation:  BufferAllocation,
  skinning:          Maybe(Skinning),
  using meta:        ResourceMetadata,
}

mesh_destroy :: proc(self: ^Mesh, manager: ^Manager) {
  manager_free_vertices(manager, self.vertex_allocation)
  manager_free_indices(manager, self.index_allocation)
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  manager_free_vertex_skinning(manager, skin.vertex_skinning_allocation)
  for &bone in skin.bones do bone_destroy(&bone)
  delete(skin.bones)
  delete(skin.bone_lengths)
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
        animation.channel_sample_all(clip.channels[entry.bone], t)
    } else {
      local_transform.scale = [3]f32{1, 1, 1}
      local_transform.rotation = linalg.QUATERNIONF32_IDENTITY
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

// Compute all bone lengths from bind pose
// Traverses skeleton hierarchy and stores distance from parent to each bone
compute_bone_lengths :: proc(skin: ^Skinning) {
  bone_count := len(skin.bones)
  if bone_count == 0 do return
  // Allocate bone lengths array
  skin.bone_lengths = make([]f32, bone_count)
  // Get bind pose positions (inverse of inverse_bind_matrix)
  bind_positions := make([][3]f32, bone_count, context.temp_allocator)
  for bone, i in skin.bones {
    bind_matrix := linalg.matrix4_inverse(bone.inverse_bind_matrix)
    bind_positions[i] = bind_matrix[3].xyz
  }
  // Traverse hierarchy and compute distances
  TraverseEntry :: struct {
    bone_idx:   u32,
    parent_pos: [3]f32,
  }
  stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)
  // Root has no parent, length = 0
  root_pos := bind_positions[skin.root_bone_index]
  skin.bone_lengths[skin.root_bone_index] = 0
  // Queue root's children
  root_bone := &skin.bones[skin.root_bone_index]
  for child_idx in root_bone.children {
    append(&stack, TraverseEntry{child_idx, root_pos})
  }
  // Process all bones
  for len(stack) > 0 {
    entry := pop(&stack)
    bone := &skin.bones[entry.bone_idx]
    bone_pos := bind_positions[entry.bone_idx]
    // Compute and store length from parent
    skin.bone_lengths[entry.bone_idx] = linalg.distance(
      entry.parent_pos,
      bone_pos,
    )
    // Queue children with this bone's position
    for child_idx in bone.children {
      append(&stack, TraverseEntry{child_idx, bone_pos})
    }
  }
}

// Sample and blend multiple animation layers (FK + IK)
// Layers are evaluated in order, with their weights controlling blending
sample_layers :: proc(
  self: ^Mesh,
  rm: ^Manager,
  layers: []animation.Layer,
  ik_targets: []animation.IKTarget,
  out_bone_matrices: []matrix[4, 4]f32,
) {
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  bone_count := len(skin.bones)
  if len(out_bone_matrices) < bone_count do return
  if len(layers) == 0 do return

  // Temporary storage for accumulating transforms
  accumulated_positions := make([][3]f32, bone_count, context.temp_allocator)
  accumulated_rotations := make(
    []quaternion128,
    bone_count,
    context.temp_allocator,
  )
  accumulated_scales := make([][3]f32, bone_count, context.temp_allocator)
  accumulated_weights := make([]f32, bone_count, context.temp_allocator)

  // Initialize accumulators
  for i in 0 ..< bone_count {
    accumulated_positions[i] = {0, 0, 0}
    accumulated_rotations[i] = linalg.QUATERNIONF32_IDENTITY
    accumulated_scales[i] = {0, 0, 0}
    accumulated_weights[i] = 0
  }

  // Sample and accumulate FK layers
  for &layer in layers {
    if layer.weight <= 0 do continue

    switch &layer_data in layer.data {
    case animation.FKLayer:
      // Resolve clip handle at runtime
      clip_handle := transmute(Handle)layer_data.clip_handle
      clip := cont.get(rm.animation_clips, clip_handle) or_continue

      // Sample this layer's animation
      TraverseEntry :: struct {
        transform: matrix[4, 4]f32,
        bone:      u32,
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
        bone := &skin.bones[entry.bone]
        local_transform: geometry.Transform
        if entry.bone < u32(len(clip.channels)) {
          local_transform.position, local_transform.rotation, local_transform.scale =
            animation.channel_sample_all(
              clip.channels[entry.bone],
              layer_data.time,
            )
        } else {
          local_transform.scale = [3]f32{1, 1, 1}
          local_transform.rotation = linalg.QUATERNIONF32_IDENTITY
        }

        // Accumulate weighted transform
        w := layer.weight
        accumulated_positions[entry.bone] += local_transform.position * w
        accumulated_rotations[entry.bone] =
          linalg.quaternion_slerp(accumulated_rotations[entry.bone], local_transform.rotation, w / (accumulated_weights[entry.bone] + w)) if accumulated_weights[entry.bone] > 0 else local_transform.rotation
        accumulated_scales[entry.bone] += local_transform.scale * w
        accumulated_weights[entry.bone] += w

        for child_index in bone.children {
          append(&stack, TraverseEntry{entry.transform, child_index})
        }
      }

    case animation.IKLayer:
      // IK layers are applied after FK as post-process (handled below)
      continue
    }
  }

  // Normalize accumulated transforms and compute world transforms
  world_transforms := make(
    []animation.BoneTransform,
    bone_count,
    context.temp_allocator,
  )

  TraverseEntry :: struct {
    parent_world: matrix[4, 4]f32,
    bone_index:   u32,
  }
  stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)
  append(
    &stack,
    TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
  )

  for len(stack) > 0 {
    entry := pop(&stack)
    bone := &skin.bones[entry.bone_index]
    bone_idx := entry.bone_index

    // Normalize accumulated transforms
    local_transform: geometry.Transform
    if accumulated_weights[bone_idx] > 0 {
      weight := accumulated_weights[bone_idx]
      local_transform.position = accumulated_positions[bone_idx] / weight
      local_transform.rotation = linalg.normalize(
        accumulated_rotations[bone_idx],
      )
      local_transform.scale = accumulated_scales[bone_idx] / weight
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
    world_transforms[bone_idx].world_matrix = world_matrix
    world_transforms[bone_idx].world_position = world_matrix[3].xyz
    world_transforms[bone_idx].world_rotation = linalg.quaternion_from_matrix4(
      world_matrix,
    )

    for child_idx in bone.children {
      append(&stack, TraverseEntry{world_matrix, child_idx})
    }
  }

  // Apply IK targets (from both layer-embedded IK and external IK targets)
  all_ik_targets := make(
    [dynamic]animation.IKTarget,
    0,
    context.temp_allocator,
  )

  // Collect IK from layers
  for &layer in layers {
    if layer.weight <= 0 do continue
    switch &layer_data in layer.data {
    case animation.IKLayer:
      target := layer_data.target
      target.weight = layer.weight
      append(&all_ik_targets, target)
    case animation.FKLayer:
      continue
    }
  }

  // Add external IK targets
  for target in ik_targets {
    append(&all_ik_targets, target)
  }

  // Apply all IK
  for target in all_ik_targets {
    if !target.enabled do continue
    chain_length := len(target.bone_indices)
    bone_lengths := make([]f32, chain_length - 1, context.temp_allocator)
    for i in 0 ..< chain_length - 1 {
      child_bone_idx := target.bone_indices[i + 1]
      bone_lengths[i] = skin.bone_lengths[child_bone_idx]
    }
    animation.fabrik_solve(world_transforms[:], target, bone_lengths[:])
  }

  // Update child bones after IK (same as sample_clip_with_ik)
  if len(all_ik_targets) > 0 {
    affected_bones := make(map[u32]bool, bone_count, context.temp_allocator)
    for target in all_ik_targets {
      if !target.enabled do continue
      for bone_idx in target.bone_indices {
        affected_bones[bone_idx] = true
      }
    }

    update_stack := make(
      [dynamic]TraverseEntry,
      0,
      bone_count,
      context.temp_allocator,
    )
    for bone_idx in affected_bones {
      bone := &skin.bones[bone_idx]
      parent_world := world_transforms[bone_idx].world_matrix
      for child_idx in bone.children {
        if child_idx in affected_bones do continue
        append(&update_stack, TraverseEntry{parent_world, child_idx})
      }
    }

    for len(update_stack) > 0 {
      entry := pop(&update_stack)
      bone := &skin.bones[entry.bone_index]
      bone_idx := entry.bone_index

      // Get normalized local transform
      local_transform: geometry.Transform
      if accumulated_weights[bone_idx] > 0 {
        weight := accumulated_weights[bone_idx]
        local_transform.position = accumulated_positions[bone_idx] / weight
        local_transform.rotation = linalg.normalize(
          accumulated_rotations[bone_idx],
        )
        local_transform.scale = accumulated_scales[bone_idx] / weight
      } else {
        local_transform.scale = [3]f32{1, 1, 1}
        local_transform.rotation = linalg.QUATERNIONF32_IDENTITY
      }

      local_matrix := linalg.matrix4_from_trs(
        local_transform.position,
        local_transform.rotation,
        local_transform.scale,
      )

      world_matrix := entry.parent_world * local_matrix
      world_transforms[bone_idx].world_matrix = world_matrix
      world_transforms[bone_idx].world_position = world_matrix[3].xyz
      world_transforms[bone_idx].world_rotation =
        linalg.quaternion_from_matrix4(world_matrix)

      for child_idx in bone.children {
        append(&update_stack, TraverseEntry{world_matrix, child_idx})
      }
    }
  }

  // Compute final skinning matrices
  for i in 0 ..< bone_count {
    world_matrix := world_transforms[i].world_matrix
    out_bone_matrices[i] = world_matrix * skin.bones[i].inverse_bind_matrix
  }
}

// Sample animation clip with IK corrections applied
// This version first computes FK, then applies IK targets, then outputs skinning matrices
sample_clip_with_ik :: proc(
  self: ^Mesh,
  clip: ^animation.Clip,
  t: f32,
  ik_targets: []animation.IKTarget,
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
  stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)
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
        animation.channel_sample_all(clip.channels[bone_idx], t)
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
    world_transforms[bone_idx].world_position = world_matrix[3].xyz
    world_transforms[bone_idx].world_rotation = linalg.quaternion_from_matrix4(
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
    chain_length := len(target.bone_indices)
    bone_lengths := make([]f32, chain_length - 1, context.temp_allocator)
    // bone_lengths[child] = distance from parent to child
    // For chain [A, B, C], we need: [length(A->B), length(B->C)]
    // Which is: [bone_lengths[B], bone_lengths[C]]
    for i in 0 ..< chain_length - 1 {
      child_bone_idx := target.bone_indices[i + 1]
      bone_lengths[i] = skin.bone_lengths[child_bone_idx]
    }
    // Apply IK
    animation.fabrik_solve(world_transforms[:], target, bone_lengths[:])
  }
  // Phase 2.5: Update child bones after IK modifications
  // After IK modifies parent bones, we need to recompute world transforms for their children
  // to maintain hierarchical consistency
  if len(ik_targets) > 0 {
    // Collect all bones affected by IK
    affected_bones := make(map[u32]bool, bone_count, context.temp_allocator)
    for target in ik_targets {
      if !target.enabled do continue
      for bone_idx in target.bone_indices {
        affected_bones[bone_idx] = true
      }
    }
    // Recompute world transforms for children of affected bones
    update_stack := make(
      [dynamic]TraverseEntry,
      0,
      bone_count,
      context.temp_allocator,
    )
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
          animation.channel_sample_all(clip.channels[bone_idx], t)
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
      world_transforms[bone_idx].world_position = world_matrix[3].xyz
      world_transforms[bone_idx].world_rotation =
        linalg.quaternion_from_matrix4(world_matrix)
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
  handle, mesh, ok = cont.alloc(&manager.meshes)
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

mesh_destroy_handle :: proc(device: vk.Device, manager: ^Manager, handle: Handle) {
  if mesh, ok := cont.get(manager.meshes, handle); ok {
    mesh_destroy(mesh, manager)
    cont.free(&manager.meshes, handle)
  }
}
