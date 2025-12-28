package world

import anim "../animation"
import cont "../containers"
import "../geometry"
import "../gpu"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

animation_instance_update :: proc(self: ^AnimationInstance, delta_time: f32) {
  if self.status != .PLAYING || self.duration <= 0 {
    return
  }
  effective_delta_time := delta_time * self.speed
  switch self.mode {
  case .LOOP:
    self.time += effective_delta_time
    self.time = math.mod_f32(self.time + self.duration, self.duration)
  case .ONCE:
    self.time += effective_delta_time
    self.time = math.mod_f32(self.time + self.duration, self.duration)
    if self.time >= self.duration {
      self.time = self.duration
      self.status = .STOPPED
    }
  case .PING_PONG:
    self.time += effective_delta_time
    if self.time >= self.duration || self.time < 0 {
      self.speed *= -1
    }
  }
}

update_skeletal_animations :: proc(
  world: ^World,
  rm: ^resources.Manager,
  delta_time: f32,
  frame_index: u32,
) {
  if delta_time <= 0 do return
  bone_buffer := &rm.bone_buffer.buffers[frame_index]
  if bone_buffer.mapped == nil do return
  for handle in world.animatable_nodes {
    node := cont.get(world.nodes, handle) or_continue
    mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
    if !has_mesh do continue
    skinning, has_skin := &mesh_attachment.skinning.?
    if !has_skin do continue
    if len(skinning.layers) == 0 do continue
    mesh := cont.get(rm.meshes, mesh_attachment.handle) or_continue
    mesh_skinning, mesh_has_skin := mesh.skinning.?
    if !mesh_has_skin do continue
    bone_count := len(mesh_skinning.bones)
    if bone_count == 0 do continue
    if skinning.bone_matrix_buffer_offset == 0xFFFFFFFF do continue
    for &layer in skinning.layers {
      anim.layer_update(&layer, delta_time)
    }
    matrices_ptr := gpu.get(
      bone_buffer,
      skinning.bone_matrix_buffer_offset,
    )
    matrices := slice.from_ptr(matrices_ptr, bone_count)
    resources.sample_layers(mesh, rm, skinning.layers[:], nil, matrices)
  }
}

// Update all node animations (generic node transform animations)
// This animates the node's local transform (position, rotation, scale)
// Works for any node type: lights, static meshes, cameras, etc.
update_node_animations :: proc(
  world: ^World,
  rm: ^resources.Manager,
  delta_time: f32,
) {
  if delta_time <= 0 do return
  for handle in world.animatable_nodes {
    node := cont.get(world.nodes, handle) or_continue
    anim_inst, has_anim := &node.animation.?
    if !has_anim do continue
    clip, clip_ok := cont.get(rm.animation_clips, anim_inst.clip_handle)
    if !clip_ok do continue
    animation_instance_update(anim_inst, delta_time)
    if len(clip.channels) > 0 {
      position, rotation, scale := anim.channel_sample_some(
        clip.channels[0],
        anim_inst.time,
      )
      if pos, has_pos := position.?; has_pos {
        node.transform.position = pos
        node.transform.is_dirty = true
      }
      if rot, has_rot := rotation.?; has_rot {
        node.transform.rotation = rot
        node.transform.is_dirty = true
      }
      if scl, has_scl := scale.?; has_scl {
        node.transform.scale = scl
        node.transform.is_dirty = true
      }
    }
  }
}

// Update all sprite animations
update_sprite_animations :: proc(rm: ^resources.Manager, delta_time: f32) {
  if delta_time <= 0 do return

  for handle in rm.animatable_sprites {
    sprite := cont.get(rm.sprites, handle) or_continue
    anim_inst, has_anim := &sprite.animation.?
    if !has_anim do continue
    resources.sprite_animation_update(anim_inst, delta_time)
    resources.sprite_write_to_gpu(rm, handle, sprite)
  }
}

// Play animation on layer 0 (for backward compatibility)
play_animation :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
  name: string,
  mode: anim.PlayMode = .LOOP,
  speed: f32 = 1.0,
) -> bool {
  return add_animation_layer(world, rm, node_handle, name, 1.0, mode, speed, 0)
}

// Add or replace an animation layer at specified index
add_animation_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
  animation_name: string,
  weight: f32 = 1.0,
  mode: anim.PlayMode = .LOOP,
  speed: f32 = 1.0,
  layer_index: int = -1, // -1 means append new layer
) -> bool {
  if rm == nil do return false
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  cont.is_valid(rm.meshes, mesh_attachment.handle) or_return
  // Get or initialize skinning
  if _, has_skin := &mesh_attachment.skinning.?; !has_skin {
    // Initialize skinning with empty layers
    mesh_attachment.skinning = NodeSkinning {
      bone_matrix_buffer_offset = 0xFFFFFFFF,
    }
  }
  skinning := &mesh_attachment.skinning.?
  // Find animation clip handle and duration
  clip_handle: resources.ClipHandle
  clip_duration: f32
  found := false
  // TODO: use linear search as a first working implementation
  // later we need to do better than this linear search
  for &entry, idx in rm.animation_clips.entries do if entry.active {
    if entry.item.name == animation_name {
      clip_handle = resources.ClipHandle {
        index      = u32(idx),
        generation = entry.generation,
      }
      clip_duration = entry.item.duration
      found = true
      break
    }
  }
  if !found do return false
  // Create new layer with handle
  layer: anim.Layer
  clip_handle_u64 := transmute(u64)clip_handle
  anim.layer_init_fk(
    &layer,
    clip_handle_u64,
    clip_duration,
    weight,
    mode,
    speed,
  )
  // Add or replace layer
  if layer_index >= 0 && layer_index < len(skinning.layers) {
    skinning.layers[layer_index] = layer
  } else {
    append(&skinning.layers, layer)
  }
  register_animatable_node(world, node_handle)
  return true
}

// Remove animation layer at specified index
remove_animation_layer :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
  layer_index: int,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  unordered_remove(&skinning.layers, layer_index)
  return true
}

// Set weight for an animation layer
set_animation_layer_weight :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
  layer_index: int,
  weight: f32,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  skinning.layers[layer_index].weight = clamp(weight, 0.0, 1.0)
  return true
}

// Clear all animation layers
clear_animation_layers :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false

  clear(&skinning.layers)
  if _, has_node_anim := node.animation.?; !has_node_anim {
    unregister_animatable_node(world, node_handle)
  }
  return true
}

// Convert world-space position to skeleton-local space
world_to_skeleton_local :: proc(
  node_world_inv: matrix[4, 4]f32,
  world_pos: [3]f32,
) -> [3]f32 {
  world_h := linalg.Vector4f32{world_pos.x, world_pos.y, world_pos.z, 1.0}
  local_h := node_world_inv * world_h
  return local_h.xyz
}

// Add an IK layer at specified index
// IK targets are in world space and will be converted to skeleton-local space internally
add_ik_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
  bone_names: []string,
  target_world_pos: [3]f32,
  pole_world_pos: [3]f32,
  weight: f32 = 1.0,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  layer_index: int = -1, // -1 to append, >= 0 to replace existing layer
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  mesh := cont.get(rm.meshes, mesh_attachment.handle) or_return
  // Get or initialize skinning
  if _, has_skin := &mesh_attachment.skinning.?; !has_skin {
    mesh_attachment.skinning = NodeSkinning {
      bone_matrix_buffer_offset = 0xFFFFFFFF,
    }
  }
  skinning := &mesh_attachment.skinning.?
  // Resolve bone names to indices
  if len(bone_names) < 2 do return false
  bone_indices := make([]u32, len(bone_names))
  for name, i in bone_names {
    idx, ok := resources.find_bone_by_name(mesh, name)
    if !ok {
      delete(bone_indices)
      return false
    }
    bone_indices[i] = idx
  }
  // Transform IK target from world space to skeleton-local space
  node_world_inv := linalg.matrix4_inverse(node.transform.world_matrix)
  target_local := world_to_skeleton_local(node_world_inv, target_world_pos)
  pole_local := world_to_skeleton_local(node_world_inv, pole_world_pos)

  // Pre-compute and cache bone lengths for IK chain
  mesh_skin, has_mesh_skin := mesh.skinning.?
  if !has_mesh_skin {
    delete(bone_indices)
    return false
  }
  chain_length := len(bone_names)
  bone_lengths := make([]f32, chain_length - 1)
  for i in 0 ..< chain_length - 1 {
    child_bone_idx := bone_indices[i + 1]
    bone_lengths[i] = mesh_skin.bone_lengths[child_bone_idx]
  }

  // Create IK target (in skeleton-local space)
  ik_target := anim.IKTarget {
    bone_indices    = bone_indices,
    bone_lengths    = bone_lengths,
    target_position = target_local,
    pole_vector     = pole_local,
    max_iterations  = max_iterations,
    tolerance       = tolerance,
    weight          = clamp(weight, 0.0, 1.0),
    enabled         = true,
  }

  // Create IK layer
  layer: anim.Layer
  anim.layer_init_ik(&layer, ik_target, weight)

  // Add or replace layer
  if layer_index >= 0 && layer_index < len(skinning.layers) {
    skinning.layers[layer_index] = layer
  } else {
    append(&skinning.layers, layer)
  }

  register_animatable_node(world, node_handle)
  return true
}

// Update IK target position and pole vector for an existing IK layer
// Targets are in world space and will be converted to skeleton-local space internally
set_ik_layer_target :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
  layer_index: int,
  target_world_pos: [3]f32,
  pole_world_pos: [3]f32,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  // Transform from world space to skeleton-local space
  node_world_inv := linalg.matrix4_inverse(node.transform.world_matrix)
  target_local := world_to_skeleton_local(node_world_inv, target_world_pos)
  pole_local := world_to_skeleton_local(node_world_inv, pole_world_pos)

  // Check if this is an IK layer
  switch &layer_data in skinning.layers[layer_index].data {
  case anim.IKLayer:
    layer_data.target.target_position = target_local
    layer_data.target.pole_vector = pole_local
    return true
  case anim.FKLayer:
    return false
  }

  return false
}

// Enable or disable an IK layer
set_ik_layer_enabled :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
  layer_index: int,
  enabled: bool,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, ok := &node.attachment.(MeshAttachment)
  if !ok do return false
  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false
  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  // Check if this is an IK layer
  switch &layer_data in skinning.layers[layer_index].data {
  case anim.IKLayer:
    layer_data.target.enabled = enabled
    return true
  case anim.FKLayer:
    return false
  }

  return false
}
