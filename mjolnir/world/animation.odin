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
    resources.sample_layers(mesh, rm, skinning.layers[:], nil, matrices, delta_time, node.transform.world_matrix)
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
  #partial switch &layer_data in skinning.layers[layer_index].data {
  case anim.IKLayer:
    layer_data.target.target_position = target_local
    layer_data.target.pole_vector = pole_local
    return true
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
  #partial switch &layer_data in skinning.layers[layer_index].data {
  case anim.IKLayer:
    layer_data.target.enabled = enabled
    return true
  }

  return false
}

resolve_bone_chain :: proc(
  mesh: ^resources.Mesh,
  root_bone_name: string,
  chain_length: u32,
  allocator := context.allocator,
) -> (
  bone_indices: []u32,
  ok: bool,
) {
  skin, has_skin := &mesh.skinning.?
  if !has_skin do return nil, false

  root_idx, found := resources.find_bone_by_name(mesh, root_bone_name)
  if !found do return nil, false

  indices := make([dynamic]u32, 0, chain_length, context.temp_allocator)
  append(&indices, root_idx)

  current_idx := root_idx
  for len(indices) < int(chain_length) {
    bone := &skin.bones[current_idx]
    if len(bone.children) == 0 do break

    child_idx := bone.children[0]
    append(&indices, child_idx)
    current_idx = child_idx
  }

  if len(indices) < 2 do return nil, false

  result := make([]u32, len(indices), allocator)
  copy(result, indices[:])
  return result, true
}

add_tail_modifier_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
  root_bone_name: string,
  tail_length: u32,
  propagation_speed: f32 = 0.5,
  damping: f32 = 0.9,
  weight: f32 = 1.0,
  layer_index: int = -1,
  reverse_chain: bool = false, // Set true if root is at tail end (reverses to head→tail)
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
  if !has_mesh do return false

  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false

  mesh := cont.get(rm.meshes, mesh_attachment.handle) or_return

  bone_indices := resolve_bone_chain(mesh, root_bone_name, tail_length) or_return

  // Reverse the chain if needed (when root is at tail, we want head→tail order)
  if reverse_chain {
    slice.reverse(bone_indices)
  }

  chain_length := len(bone_indices)

  // Initialize per-bone state for tail animation
  bones := make([]anim.TailBone, chain_length)
  for i in 0 ..< chain_length {
    bones[i] = anim.TailBone {
      target_tip_world = {0, 0, 0},
      is_initialized   = false,
    }
  }

  layer := anim.Layer {
    weight = weight,
    data   = anim.ProceduralLayer {
      state = anim.ProceduralState {
        bone_indices = bone_indices,
        accumulated_time = 0,
        modifier = anim.TailModifier {
          propagation_speed = propagation_speed,
          damping = damping,
          bones = bones,
        },
      },
    },
  }

  if layer_index < 0 || layer_index >= len(skinning.layers) {
    append(&skinning.layers, layer)
  } else {
    skinning.layers[layer_index] = layer
  }

  register_animatable_node(world, node_handle)
  return true
}

add_path_modifier_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
  root_bone_name: string,
  tail_length: u32,
  path: [][3]f32,
  offset: f32 = 0.0,
  length: f32 = 0.0,  // Length of path segment to fit skeleton (0 = auto-calculate from offset to end)
  speed: f32 = 0.0,
  loop: bool = false,
  weight: f32 = 1.0,
  layer_index: int = -1,
) -> bool {
  if len(path) < 2 do return false

  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
  if !has_mesh do return false

  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false

  mesh := cont.get(rm.meshes, mesh_attachment.handle) or_return

  bone_indices := resolve_bone_chain(mesh, root_bone_name, tail_length) or_return

  points := make([][3]f32, len(path))
  copy(points, path)

  times := make([]f32, len(path))
  for i in 0 ..< len(times) {
    times[i] = f32(i)
  }

  spline := anim.Spline([3]f32) {
    points = points,
    times  = times,
  }

  layer := anim.Layer {
    weight = weight,
    data   = anim.ProceduralLayer {
      state = anim.ProceduralState {
        bone_indices = bone_indices,
        accumulated_time = 0,
        modifier = anim.PathModifier {
          spline = spline,
          offset = offset,
          length = length,
          speed = speed,
          loop = loop,
        },
      },
    },
  }

  if layer_index < 0 || layer_index >= len(skinning.layers) {
    append(&skinning.layers, layer)
  } else {
    skinning.layers[layer_index] = layer
  }

  register_animatable_node(world, node_handle)
  return true
}

add_spider_leg_modifier_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
  leg_root_names: []string,
  leg_chain_lengths: []u32,
  leg_configs: []anim.SpiderLegConfig,
  weight: f32 = 1.0,
  layer_index: int = -1,
) -> bool {
  if len(leg_root_names) != len(leg_chain_lengths) do return false
  if len(leg_root_names) != len(leg_configs) do return false
  if len(leg_root_names) == 0 do return false

  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
  if !has_mesh do return false

  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false

  mesh := cont.get(rm.meshes, mesh_attachment.handle) or_return

  num_legs := len(leg_root_names)
  all_bone_indices := make([dynamic]u32, 0, context.temp_allocator)
  chain_starts := make([]u32, num_legs)
  chain_lengths := make([]u32, num_legs)
  legs := make([]anim.SpiderLeg, num_legs)

  for i in 0 ..< num_legs {
    leg_indices := resolve_bone_chain(
      mesh,
      leg_root_names[i],
      leg_chain_lengths[i],
    ) or_return
    defer delete(leg_indices)

    chain_starts[i] = u32(len(all_bone_indices))
    chain_lengths[i] = u32(len(leg_indices))

    for idx in leg_indices {
      append(&all_bone_indices, idx)
    }

    cfg := leg_configs[i]
    anim.spider_leg_init(
      &legs[i],
      cfg.initial_offset,
      cfg.lift_height,
      cfg.lift_frequency,
      cfg.lift_duration,
      cfg.time_offset,
    )
  }

  bone_indices := make([]u32, len(all_bone_indices))
  copy(bone_indices, all_bone_indices[:])

  layer := anim.Layer {
    weight = weight,
    data   = anim.ProceduralLayer {
      state = anim.ProceduralState {
        bone_indices     = bone_indices,
        accumulated_time = 0,
        modifier         = anim.SpiderLegModifier {
          legs          = legs,
          chain_starts  = chain_starts,
          chain_lengths = chain_lengths,
        },
      },
    },
  }

  if layer_index < 0 || layer_index >= len(skinning.layers) {
    append(&skinning.layers, layer)
  } else {
    skinning.layers[layer_index] = layer
  }

  register_animatable_node(world, node_handle)
  return true
}

get_spider_leg_target :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
  layer_index: int,
  leg_index: int,
) -> (target: ^[3]f32, ok: bool) {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
  if !has_mesh do return nil, false

  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return nil, false

  if layer_index < 0 || layer_index >= len(skinning.layers) do return nil, false

  #partial switch &layer_data in skinning.layers[layer_index].data {
  case anim.ProceduralLayer:
    #partial switch &modifier in layer_data.state.modifier {
    case anim.SpiderLegModifier:
      if leg_index < 0 || leg_index >= len(modifier.legs) do return nil, false
      return &modifier.legs[leg_index].feet_target, true
    }
  }

  return nil, false
}

set_tail_modifier_params :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
  layer_index: int,
  propagation_speed: Maybe(f32) = nil,
  damping: Maybe(f32) = nil,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
  if !has_mesh do return false

  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false

  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  switch &layer_data in skinning.layers[layer_index].data {
  case anim.ProceduralLayer:
    switch &modifier in layer_data.state.modifier {
    case anim.TailModifier:
      if prop, has_prop := propagation_speed.?; has_prop {
        modifier.propagation_speed = prop
      }
      if damp, has_damp := damping.?; has_damp {
        modifier.damping = damp
      }
      return true
    case anim.PathModifier, anim.SpiderLegModifier, anim.SingleBoneRotationModifier:
      return false
    }
  case anim.FKLayer, anim.IKLayer:
    return false
  }

  return false
}

set_path_modifier_params :: proc(
  world: ^World,
  node_handle: resources.NodeHandle,
  layer_index: int,
  path: Maybe([][3]f32) = nil,
  offset: Maybe(f32) = nil,
  length: Maybe(f32) = nil,
  speed: Maybe(f32) = nil,
  loop: Maybe(bool) = nil,
) -> bool {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
  if !has_mesh do return false

  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return false

  if layer_index < 0 || layer_index >= len(skinning.layers) do return false

  switch &layer_data in skinning.layers[layer_index].data {
  case anim.ProceduralLayer:
    switch &modifier in layer_data.state.modifier {
    case anim.PathModifier:
      if new_path, has_path := path.?; has_path {
        if len(new_path) >= 2 {
          anim.spline_destroy(&modifier.spline)

          points := make([][3]f32, len(new_path))
          copy(points, new_path)

          times := make([]f32, len(new_path))
          for i in 0 ..< len(times) {
            times[i] = f32(i)
          }

          modifier.spline = anim.Spline([3]f32) {
            points = points,
            times  = times,
          }
        }
      }
      if off, has_off := offset.?; has_off {
        modifier.offset = off
      }
      if len_val, has_len := length.?; has_len {
        modifier.length = len_val
      }
      if spd, has_spd := speed.?; has_spd {
        modifier.speed = spd
      }
      if lp, has_lp := loop.?; has_lp {
        modifier.loop = lp
      }
      return true
    case anim.TailModifier, anim.SpiderLegModifier, anim.SingleBoneRotationModifier:
      return false
    }
  case anim.FKLayer, anim.IKLayer:
    return false
  }

  return false
}

add_single_bone_rotation_modifier_layer :: proc(
  world: ^World,
  rm: ^resources.Manager,
  node_handle: resources.NodeHandle,
  bone_name: string,
  weight: f32 = 1.0,
  layer_index: int = -1,
) -> (modifier: ^anim.SingleBoneRotationModifier, ok: bool) {
  node := cont.get(world.nodes, node_handle) or_return
  mesh_attachment, has_mesh := &node.attachment.(MeshAttachment)
  if !has_mesh do return nil, false

  skinning, has_skin := &mesh_attachment.skinning.?
  if !has_skin do return nil, false

  mesh := cont.get(rm.meshes, mesh_attachment.handle) or_return

  // Resolve bone name to index
  bone_idx, found := resources.find_bone_by_name(mesh, bone_name)
  if !found do return nil, false

  // Initialize rotation to identity
  identity := quaternion128{}
  identity.w = 1

  layer := anim.Layer {
    weight = weight,
    data   = anim.ProceduralLayer {
      state = anim.ProceduralState {
        bone_indices     = nil, // Single bone modifier doesn't use this array
        accumulated_time = 0,
        modifier         = anim.SingleBoneRotationModifier {
          bone_index = bone_idx,
          rotation   = identity,
        },
      },
    },
  }

  if layer_index < 0 || layer_index >= len(skinning.layers) {
    append(&skinning.layers, layer)
  } else {
    skinning.layers[layer_index] = layer
  }

  register_animatable_node(world, node_handle)

  // Return pointer to the modifier so caller can update rotation
  layer_ptr := &skinning.layers[len(skinning.layers) - 1] if layer_index < 0 else &skinning.layers[layer_index]
  #partial switch &layer_data in layer_ptr.data {
  case anim.ProceduralLayer:
    #partial switch &mod in layer_data.state.modifier {
    case anim.SingleBoneRotationModifier:
      return &mod, true
    }
  }

  return nil, false
}
