package world

import "../animation"
import cont "../containers"
import "../geometry"
import "core:log"
import "core:math/linalg"

Mesh :: struct {
  aabb_min:                    [3]f32,
  index_count:                 u32,
  aabb_max:                    [3]f32,
  skinning:                    Maybe(Skinning),
  cpu_geometry:                Maybe(geometry.Geometry),
  auto_purge_cpu_geometry:     bool,
}

find_bone_by_name :: proc(
  self: ^Mesh,
  name: string,
) -> (
  index: u32,
  ok: bool,
) #optional_ok {
  skin, has_skin := &self.skinning.?
  if !has_skin do return
  for bone, i in skin.bones {
    if bone.name == name {
      return u32(i), true
    }
  }
  return 0, false
}

// Build parent index map for efficient traversal
// Returns map of child_index -> parent_index
build_bone_parent_map :: proc(
  skin: ^Skinning,
  allocator := context.allocator,
) -> map[u32]u32 {
  parent_map := make(map[u32]u32, len(skin.bones), allocator)
  for bone, idx in skin.bones {
    for child_idx in bone.children {
      parent_map[child_idx] = u32(idx)
    }
  }
  return parent_map
}

// Find bone chain from tip to root
// Walks skeleton hierarchy and returns ordered array of bone names (root -> tip)
// Returns error if tip is not a descendant of root
find_bone_chain_to_root :: proc(
  skin: ^Skinning,
  tip_name: string,
  root_name: string,
  allocator := context.allocator,
) -> (
  chain: []string,
  ok: bool,
) #optional_ok {
  // Build name→index map
  name_to_idx := make(map[string]u32, len(skin.bones), context.temp_allocator)
  defer delete(name_to_idx)

  for bone, idx in skin.bones {
    name_to_idx[bone.name] = u32(idx)
  }

  root_idx, has_root := name_to_idx[root_name]
  tip_idx, has_tip := name_to_idx[tip_name]
  if !has_root || !has_tip do return nil, false

  // Build parent map
  parent_map := build_bone_parent_map(skin, context.temp_allocator)
  defer delete(parent_map)

  // Walk from tip to root
  chain_indices := make([dynamic]u32, context.temp_allocator)
  defer delete(chain_indices)

  current := tip_idx
  for {
    append(&chain_indices, current)
    if current == root_idx do break
    parent, has_parent := parent_map[current]
    if !has_parent do return nil, false // tip not descendant of root
    current = parent
  }

  // Reverse to get root→tip order
  chain = make([]string, len(chain_indices), allocator)
  for i in 0 ..< len(chain_indices) {
    idx := chain_indices[len(chain_indices) - 1 - i]
    chain[i] = skin.bones[idx].name
  }

  return chain, true
}

// Batch bone name lookup
// Returns array of bone indices matching the provided names
// Returns error if any name is not found
find_bones_by_names :: proc(
  mesh: ^Mesh,
  names: []string,
  allocator := context.allocator,
) -> (
  indices: []u32,
  ok: bool,
) #optional_ok {
  skin := mesh.skinning.? or_return
  indices = make([]u32, len(names), allocator)
  for name, i in names {
    idx, found := find_bone_by_name(mesh, name)
    if !found {
      delete(indices)
      return nil, false
    }
    indices[i] = idx
  }
  return indices, true
}

mesh_destroy :: proc(self: ^Mesh) {
  skin, has_skin := &self.skinning.?
  if has_skin {
    for &bone in skin.bones do bone_destroy(&bone)
    delete(skin.bones)
    delete(skin.bone_lengths)
    delete(skin.bind_matrices)
    delete(skin.bone_depths)
  }
  mesh_release_memory(self)
}

mesh_release_memory :: proc(self: ^Mesh) {
  geom, has_geom := self.cpu_geometry.?
  if !has_geom do return
  delete(geom.vertices)
  delete(geom.indices)
  delete(geom.skinnings)
  self.cpu_geometry = nil
}

// Initialize mesh CPU data only. Geometry ownership is transferred to mesh.
mesh_init :: proc(self: ^Mesh, geometry_data: geometry.Geometry) {
  self.aabb_min = geometry_data.aabb.min
  self.aabb_max = geometry_data.aabb.max
  self.cpu_geometry = geometry_data
  // Allocations are filled in outside this module after creation.
  if len(geometry_data.skinnings) > 0 {
    self.skinning = Skinning {
      bones = make([]Bone, 0),
    }
  }
}

// Sample and blend multiple animation layers (FK + IK)
// Layers are evaluated in order, with their weights controlling blending
sample_layers :: proc(
  self: ^Mesh,
  world: ^World,
  layers: []animation.Layer,
  ik_targets: []animation.IKTarget,
  out_bone_matrices: []matrix[4, 4]f32,
  delta_time: f32,
  node_world_matrix: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) {
  TraverseEntry :: struct {
    parent_transform: matrix[4, 4]f32,
    bone_index:       u32,
  }
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
  for i in 0 ..< bone_count {
    accumulated_positions[i] = {0, 0, 0}
    accumulated_rotations[i] = linalg.QUATERNIONF32_IDENTITY
    accumulated_scales[i] = {0, 0, 0}
    accumulated_weights[i] = 0
  }
  // Sample and accumulate FK layers
  for &layer in layers {
    if layer.weight <= 0 do continue
    #partial switch &layer_data in layer.data {
    case animation.FKLayer:
      // Resolve clip handle at runtime
      clip_handle := transmute(ClipHandle)layer_data.clip_handle
      clip := cont.get(world.animation_clips, clip_handle) or_continue
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
        local_transform: geometry.Transform
        if entry.bone_index < u32(len(clip.channels)) {
          local_transform.position, local_transform.rotation, local_transform.scale =
            animation.channel_sample_all(
              clip.channels[entry.bone_index],
              layer_data.time,
            )
        } else {
          local_transform.scale = [3]f32{1, 1, 1}
          local_transform.rotation = linalg.QUATERNIONF32_IDENTITY
        }

        // Check bone mask - skip if bone is masked out
        if mask, has_mask := layer.bone_mask.?; has_mask {
          if entry.bone_index >= u32(len(mask)) || !mask[entry.bone_index] {
            // Skip this bone - continue to children
            for child_index in bone.children {
              append(
                &stack,
                TraverseEntry{entry.parent_transform, child_index},
              )
            }
            continue
          }
        }

        // Accumulate weighted transform using blend mode
        w := layer.weight
        accumulated_positions[entry.bone_index] = animation.blend_position(
          accumulated_positions[entry.bone_index],
          local_transform.position,
          w,
          layer.blend_mode,
        )
        accumulated_rotations[entry.bone_index] = animation.blend_rotation(
          accumulated_rotations[entry.bone_index],
          accumulated_weights[entry.bone_index],
          local_transform.rotation,
          w,
          layer.blend_mode,
        )
        accumulated_scales[entry.bone_index] = animation.blend_scale(
          accumulated_scales[entry.bone_index],
          local_transform.scale,
          w,
          layer.blend_mode,
        )
        accumulated_weights[entry.bone_index] += w
        for child_index in bone.children {
          append(&stack, TraverseEntry{entry.parent_transform, child_index})
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
    local_matrix := linalg.MATRIX4F32_IDENTITY
    if accumulated_weights[bone_idx] > 0 {
      weight := accumulated_weights[bone_idx]
      position := accumulated_positions[bone_idx] / weight
      rotation := linalg.normalize(accumulated_rotations[bone_idx])
      scale := accumulated_scales[bone_idx] / weight
      local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
    } else {
      bind_world_matrix := linalg.matrix4_inverse(bone.inverse_bind_matrix)
      parent_inv := linalg.matrix4_inverse(entry.parent_transform)
      local_matrix = parent_inv * bind_world_matrix
    }

    // Compute world transform
    world_matrix := entry.parent_transform * local_matrix
    world_transforms[bone_idx].world_matrix = world_matrix
    world_transforms[bone_idx].world_position = world_matrix[3].xyz
    world_transforms[bone_idx].world_rotation = linalg.to_quaternion(
      world_matrix,
    )

    for child_idx in bone.children {
      append(&stack, TraverseEntry{world_matrix, child_idx})
    }
  }

  // Apply procedural modifiers
  procedural_affected_bones := make(
    map[u32]bool,
    bone_count,
    context.temp_allocator,
  )
  for &layer in layers {
    if layer.weight <= 0 do continue
    switch &layer_data in layer.data {
    case animation.ProceduralLayer:
      layer_data.state.accumulated_time += delta_time

      switch &modifier in layer_data.state.modifier {
      case animation.TailModifier:
        animation.tail_modifier_update(
          &layer_data.state,
          &modifier,
          delta_time,
          world_transforms[:],
          layer.weight,
          skin.bone_lengths,
        )
      case animation.PathModifier:
        animation.path_modifier_update(
          &layer_data.state,
          &modifier,
          delta_time,
          world_transforms[:],
          layer.weight,
          skin.bone_lengths,
        )
      case animation.SpiderLegModifier:
        animation.spider_leg_modifier_update(
          &layer_data.state,
          &modifier,
          delta_time,
          world_transforms[:],
          layer.weight,
          skin.bone_lengths,
          node_world_matrix,
        )
      case animation.SingleBoneRotationModifier:
        animation.single_bone_rotation_modifier_update(
          &layer_data.state,
          &modifier,
          delta_time,
          world_transforms[:],
          layer.weight,
          skin.bone_lengths,
        )
      }

      // Track affected bones for child update
      if layer_data.state.bone_indices != nil {
        for bone_idx in layer_data.state.bone_indices {
          procedural_affected_bones[bone_idx] = true
        }
      } else {
        // SingleBoneRotationModifier stores bone_index directly
        #partial switch &modifier in layer_data.state.modifier {
        case animation.SingleBoneRotationModifier:
          procedural_affected_bones[modifier.bone_index] = true
        }
      }
    case animation.FKLayer, animation.IKLayer:
      continue
    }
  }

  // Update child bones after procedural modifiers
  if len(procedural_affected_bones) > 0 {
    update_stack := make(
      [dynamic]TraverseEntry,
      0,
      bone_count,
      context.temp_allocator,
    )
    for bone_idx in procedural_affected_bones {
      bone := &skin.bones[bone_idx]
      parent_world := world_transforms[bone_idx].world_matrix
      for child_idx in bone.children {
        if child_idx in procedural_affected_bones do continue
        append(&update_stack, TraverseEntry{parent_world, child_idx})
      }
    }

    for len(update_stack) > 0 {
      entry := pop(&update_stack)
      bone := &skin.bones[entry.bone_index]
      bone_idx := entry.bone_index

      local_matrix := linalg.MATRIX4F32_IDENTITY
      if accumulated_weights[bone_idx] > 0 {
        weight := accumulated_weights[bone_idx]
        position := accumulated_positions[bone_idx] / weight
        rotation := linalg.normalize(accumulated_rotations[bone_idx])
        scale := accumulated_scales[bone_idx] / weight
        local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
      }
      world_matrix := entry.parent_transform * local_matrix
      world_transforms[bone_idx].world_matrix = world_matrix
      world_transforms[bone_idx].world_position = world_matrix[3].xyz
      world_transforms[bone_idx].world_rotation = linalg.to_quaternion(
        world_matrix,
      )

      for child_idx in bone.children {
        append(&update_stack, TraverseEntry{world_matrix, child_idx})
      }
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
    #partial switch &layer_data in layer.data {
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
    animation.fabrik_solve(world_transforms[:], target)
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

      local_matrix := linalg.MATRIX4F32_IDENTITY
      if accumulated_weights[bone_idx] > 0 {
        weight := accumulated_weights[bone_idx]
        position := accumulated_positions[bone_idx] / weight
        rotation := linalg.normalize(accumulated_rotations[bone_idx])
        scale := accumulated_scales[bone_idx] / weight
        local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
      }
      world_matrix := entry.parent_transform * local_matrix
      world_transforms[bone_idx].world_matrix = world_matrix
      world_transforms[bone_idx].world_position = world_matrix[3].xyz
      world_transforms[bone_idx].world_rotation = linalg.to_quaternion(
        world_matrix,
      )

      for child_idx in bone.children {
        append(&update_stack, TraverseEntry{world_matrix, child_idx})
      }
    }
  }

  // Compute final skinning matrices
  for i in 0 ..< bone_count {
    out_bone_matrices[i] =
      world_transforms[i].world_matrix * skin.bones[i].inverse_bind_matrix
  }
}

// Creates mesh in CPU resource pool.
// Geometry ownership is transferred to the mesh on success.
create_mesh :: proc(
  world: ^World,
  geometry_data: geometry.Geometry,
  auto_purge: bool = false,
) -> (
  handle: MeshHandle,
  mesh: ^Mesh,
  ok: bool,
) {
  handle, mesh, ok = cont.alloc(&world.meshes, MeshHandle)
  if !ok {
    geometry.delete_geometry(geometry_data)
    return
  }
  mesh.auto_purge_cpu_geometry = auto_purge
  mesh_init(mesh, geometry_data)
  stage_mesh_data(&world.staging, handle)
  return handle, mesh, true
}

destroy_mesh :: proc(self: ^World, handle: MeshHandle) {
  if mesh, ok := cont.free(&self.meshes, handle); ok {
    stage_mesh_removal(&self.staging, handle)
    mesh_destroy(mesh)
  }
}

Color :: enum {
  WHITE,
  BLACK,
  GRAY,
  RED,
  GREEN,
  BLUE,
  YELLOW,
  CYAN,
  MAGENTA,
}

Bone :: struct {
  children:            []u32,
  inverse_bind_matrix: matrix[4, 4]f32,
  name:                string,
}

bone_destroy :: proc(bone: ^Bone) {
  delete(bone.children)
  bone.children = nil
}

Skinning :: struct {
  root_bone_index: u32,
  bones:           []Bone,
  bone_lengths:    []f32,
  bind_matrices:   []matrix[4, 4]f32, // Cached inverse of inverse_bind_matrix
  bone_depths:     []u32,              // Cached hierarchical depth for visualization
}

Primitive :: enum {
  CUBE,
  SPHERE,
  QUAD_XZ,
  QUAD_XY,
  CONE,
  CAPSULE,
  CYLINDER,
  TORUS,
}

compute_bone_lengths :: proc(skin: ^Skinning) {
  bone_count := len(skin.bones)
  if bone_count == 0 do return
  skin.bone_lengths = make([]f32, bone_count)
  bind_positions := make([][3]f32, bone_count, context.temp_allocator)
  for bone, i in skin.bones {
    bind_matrix := linalg.matrix4_inverse(bone.inverse_bind_matrix)
    bind_positions[i] = bind_matrix[3].xyz
  }
  TraverseEntry :: struct {
    bone_idx:   u32,
    parent_pos: [3]f32,
  }
  stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)
  root_pos := bind_positions[skin.root_bone_index]
  skin.bone_lengths[skin.root_bone_index] = 0
  root_bone := &skin.bones[skin.root_bone_index]
  for child_idx in root_bone.children {
    append(&stack, TraverseEntry{child_idx, root_pos})
  }
  for len(stack) > 0 {
    entry := pop(&stack)
    bone := &skin.bones[entry.bone_idx]
    bone_pos := bind_positions[entry.bone_idx]
    skin.bone_lengths[entry.bone_idx] = linalg.distance(
      entry.parent_pos,
      bone_pos,
    )
    for child_idx in bone.children {
      append(&stack, TraverseEntry{child_idx, bone_pos})
    }
  }
}

// Calculate hierarchical depth for each bone (used for color-coded visualization)
// Returns array of depth values where root bones are depth 0, their children are depth 1, etc.
calculate_bone_depths :: proc(
  skin: ^Skinning,
  allocator := context.allocator,
) -> []u32 {
  bone_count := len(skin.bones)
  if bone_count == 0 do return nil

  depths := make([]u32, bone_count, allocator)

  // Build parent map for efficient traversal
  parent_map := build_bone_parent_map(skin, context.temp_allocator)
  defer delete(parent_map)

  // Find root bones (bones with no parent)
  roots := make([dynamic]u32, context.temp_allocator)
  defer delete(roots)

  for i in 0 ..< u32(bone_count) {
    if i not_in parent_map {
      append(&roots, i)
      depths[i] = 0
    }
  }

  // BFS to assign depths
  queue := make([dynamic]u32, context.temp_allocator)
  defer delete(queue)

  append(&queue, ..roots[:])

  for len(queue) > 0 {
    // Pop from back (more efficient than ordered_remove from front)
    current := pop(&queue)

    current_depth := depths[current]

    // Process children
    bone := &skin.bones[current]
    for child_idx in bone.children {
      depths[child_idx] = current_depth + 1
      append(&queue, child_idx)
    }
  }

  return depths
}
