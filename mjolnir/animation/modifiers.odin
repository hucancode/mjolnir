package animation

import "core:math"
import "core:math/linalg"

// Per-bone state for tail animation
// Tracks tip position to create follow-through drag effect
TailBone :: struct {
  target_tip_world: [3]f32, // Where the tip wants to be in world space (has inertia)
  is_initialized:   bool, // Flag to initialize on first frame
}

TailModifier :: struct {
  propagation_speed: f32, // How fast rotation influence travels down the chain (0-1)
  damping:           f32, // How quickly bones return to rest pose (0-1)
  bones:             []TailBone, // Per-bone state
}

PathModifier :: struct {
  spline: Spline([3]f32),
  offset: f32,
  length: f32, // Length of the path segment to fit the skeleton to
  speed:  f32,
  loop:   bool,
}

// Debug info for one IK chain
IKDebugInfo :: struct {
  positions:      [][3]f32, // Joint positions in skeleton space
  target:         [3]f32,   // Target position in skeleton space
  pole:           [3]f32,   // Pole vector position in skeleton space
  has_pole:       bool,     // Whether pole vector is active
}

SpiderLegModifier :: struct {
  legs:          []SpiderLeg,
  chain_starts:  []u32,
  chain_lengths: []u32,
  debug_info:    []IKDebugInfo, // Debug info for each leg (allocated if debug enabled)
}

// Simple modifier to directly set a single bone's rotation
// Useful for driving animations or testing
SingleBoneRotationModifier :: struct {
  bone_index: u32, // Index of the bone to modify
  rotation:   quaternion128, // Local rotation to apply
}

Modifier :: union {
  TailModifier,
  PathModifier,
  SpiderLegModifier,
  SingleBoneRotationModifier,
}

ProceduralState :: struct {
  bone_indices:     []u32,
  accumulated_time: f32,
  modifier:         Modifier,
}

ProceduralLayer :: struct {
  state: ProceduralState,
}

tail_modifier_update :: proc(
  state: ^ProceduralState,
  params: ^TailModifier,
  delta_time: f32,
  world_transforms: []BoneTransform,
  layer_weight: f32,
  bone_lengths: []f32,
) {
  chain_length := len(state.bone_indices)
  if chain_length < 2 do return
  if len(params.bones) != chain_length do return
  if bone_lengths == nil do return

  // Process each bone (starting from bone[1], skip root at bone[0])
  // Algorithm:
  // 1. Track where the bone's tip was in world space (target_tip_world)
  // 2. When bone root moves (due to parent FK), rotate bone to point at remembered tip position
  // 3. Damping: over time, move target_tip toward rest pose tip position
  for i in 1 ..< chain_length {
    bone_idx := state.bone_indices[i]
    parent_idx := state.bone_indices[i - 1]
    bone_state := &params.bones[i]

    bone_length := bone_lengths[bone_idx]

    // Get FK rotation before we modify it
    fk_up := linalg.normalize(world_transforms[bone_idx].world_matrix[1].xyz)
    fk_rotation := world_transforms[bone_idx].world_rotation

    // Update position FIRST: child's root follows parent's tip
    // Note: bone_lengths[bone_idx] is the distance from parent to this child bone
    parent_up := linalg.normalize(
      world_transforms[parent_idx].world_matrix[1].xyz,
    )
    new_position :=
      world_transforms[parent_idx].world_position + parent_up * bone_length

    world_transforms[bone_idx].world_position = linalg.lerp(
      world_transforms[bone_idx].world_position,
      new_position,
      layer_weight,
    )

    bone_world_pos := world_transforms[bone_idx].world_position

    // Calculate FK rest tip from the UPDATED position
    rest_tip := bone_world_pos + fk_up * bone_length

    // Initialize target tip position on first frame
    if !bone_state.is_initialized {
      bone_state.target_tip_world = rest_tip
      bone_state.is_initialized = true
    }

    // Calculate desired direction to point at target tip
    tip_direction := bone_state.target_tip_world - bone_world_pos
    distance := linalg.length(tip_direction)

    // Only apply rotation if we have a valid direction
    if distance > 0.001 {
      // Calculate rotation needed to point at target
      target_rotation := linalg.quaternion_between_two_vector3(
        fk_up,
        tip_direction,
      )

      // Apply rotation to world transform
      procedural_rotation := target_rotation * fk_rotation

      world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
        fk_rotation,
        procedural_rotation,
        layer_weight,
      )
    }

    // Update world matrix
    scale := extract_scale(world_transforms[bone_idx].world_matrix)
    world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
      world_transforms[bone_idx].world_position,
      world_transforms[bone_idx].world_rotation,
      scale,
    )

    // Calculate where bone now points after our rotation
    current_up := linalg.normalize(
      world_transforms[bone_idx].world_matrix[1].xyz,
    )
    current_tip := bone_world_pos + current_up * bone_length

    // Update target for next frame: blend current position with FK rest position
    // This creates inertia (follows current) and damping (returns to FK rest)
    // damping close to 1.0 = slow return to rest (more inertia)
    // damping close to 0.0 = fast return to rest (less inertia)
    damping_factor := 1.0 - math.pow(params.damping, delta_time)
    bone_state.target_tip_world = linalg.lerp(
      current_tip, // Where we point now (inertia)
      rest_tip, // Where FK wants us (damping)
      damping_factor,
    )
  }
}

path_modifier_update :: proc(
  state: ^ProceduralState,
  params: ^PathModifier,
  delta_time: f32,
  world_transforms: []BoneTransform,
  layer_weight: f32,
  bone_lengths: []f32,
) {
  chain_length := len(state.bone_indices)
  if chain_length < 2 || len(params.spline.points) < 2 do return

  // Build arc table BEFORE updating offset!
  if _, has_table := params.spline.arc_table.?; !has_table {
    spline_build_arc_table(&params.spline)
  }

  if bone_lengths == nil do return

  // Now update offset after arc table exists
  if params.speed != 0 {
    params.offset += params.speed * delta_time
    spline_length := spline_arc_length(params.spline)
    if params.loop {
      params.offset = math.mod_f32(params.offset, spline_length)
    } else {
      params.offset = clamp(params.offset, 0.0, spline_length)
    }
  }

  total_chain_length: f32 = 0
  for i in 1 ..< chain_length {
    total_chain_length += bone_lengths[state.bone_indices[i]]
  }

  if total_chain_length <= 0 do return

  spline_length := spline_arc_length(params.spline)

  // Determine the segment length to use
  segment_length :=
    params.length if params.length > 0 else spline_length - params.offset
  cumulative_length: f32 = 0

  // First pass: position all bones along the path segment [offset, offset + segment_length]
  for i in 0 ..< chain_length {
    bone_idx := state.bone_indices[i]

    // Map bone position to segment: offset + (bone_progress * segment_length)
    t :=
      cumulative_length / total_chain_length if total_chain_length > 0 else 0
    s := params.offset + (t * segment_length)

    // Clamp to spline bounds
    if params.loop {
      s = math.mod_f32(s, spline_length)
    } else {
      s = clamp(s, 0, spline_length)
    }

    path_pos := spline_sample_uniform(params.spline, s)

    fk_pos := world_transforms[bone_idx].world_position
    world_transforms[bone_idx].world_position = linalg.lerp(
      fk_pos,
      path_pos,
      layer_weight,
    )

    if i < chain_length - 1 {
      cumulative_length += bone_lengths[state.bone_indices[i + 1]]
    }
  }

  // Second pass: orient each parent bone toward its child
  for i in 0 ..< chain_length - 1 {
    bone_idx := state.bone_indices[i]
    child_idx := state.bone_indices[i + 1]

    // Compute direction from parent to child
    bone_direction :=
      world_transforms[child_idx].world_position -
      world_transforms[bone_idx].world_position

    // Bones typically extend along Y-axis (up) in bind pose
    bone_up := world_transforms[bone_idx].world_matrix[1].xyz
    target_rotation := linalg.quaternion_between_two_vector3(
      bone_up,
      bone_direction,
    )
    procedural_rotation :=
      target_rotation * world_transforms[bone_idx].world_rotation
    world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
      world_transforms[bone_idx].world_rotation,
      procedural_rotation,
      layer_weight,
    )

    scale := extract_scale(world_transforms[bone_idx].world_matrix)
    world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
      world_transforms[bone_idx].world_position,
      world_transforms[bone_idx].world_rotation,
      scale,
    )
  }

  // Handle last bone (no child to point to, use spline tangent)
  if chain_length > 0 {
    last_idx := chain_length - 1
    bone_idx := state.bone_indices[last_idx]

    cumulative_length = 0
    for i in 1 ..< chain_length {
      cumulative_length += bone_lengths[state.bone_indices[i]]
    }

    s :=
      params.offset +
      (cumulative_length / total_chain_length) *
        (spline_length - params.offset)
    epsilon := f32(0.01)
    s_tangent := clamp(s + epsilon, 0, spline_length)
    tangent_pos := spline_sample_uniform(params.spline, s_tangent)
    current_pos := world_transforms[bone_idx].world_position
    tangent := tangent_pos - current_pos

    // Bones typically extend along Y-axis (up) in bind pose
    bone_up := world_transforms[bone_idx].world_matrix[1].xyz
    target_rotation := linalg.quaternion_between_two_vector3(bone_up, tangent)
    procedural_rotation :=
      target_rotation * world_transforms[bone_idx].world_rotation
    world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
      world_transforms[bone_idx].world_rotation,
      procedural_rotation,
      layer_weight,
    )

    scale := extract_scale(world_transforms[bone_idx].world_matrix)
    world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
      world_transforms[bone_idx].world_position,
      world_transforms[bone_idx].world_rotation,
      scale,
    )
  }
}

spider_leg_modifier_update :: proc(
  state: ^ProceduralState,
  params: ^SpiderLegModifier,
  delta_time: f32,
  world_transforms: []BoneTransform,
  layer_weight: f32,
  bone_lengths: []f32,
  node_world_matrix: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
  debug_enabled: bool = false,
) {
  // Allocate debug info if needed
  if debug_enabled && len(params.debug_info) != len(params.legs) {
    params.debug_info = make([]IKDebugInfo, len(params.legs))
    for &info in params.debug_info {
      info.positions = make([][3]f32, 0)
    }
  }
  for &leg, leg_idx in params.legs {
    chain_start := params.chain_starts[leg_idx]
    chain_len := params.chain_lengths[leg_idx]
    if chain_len < 2 do continue
    // Get leg root bone index and position
    leg_bone_indices := state.bone_indices[chain_start:chain_start + chain_len]
    root_bone_idx := leg_bone_indices[0]
    root_position_skeleton := world_transforms[root_bone_idx].world_position
    // Convert root position from skeleton space to true world space
    root_position_world_h :=
      node_world_matrix *
      linalg.Vector4f32 {
          root_position_skeleton.x,
          root_position_skeleton.y,
          root_position_skeleton.z,
          1.0,
        }
    root_position_world := root_position_world_h.xyz
    // Update spider leg with world space root position
    // The algorithm works in world space to keep feet grounded
    spider_leg_update_with_root(&leg, delta_time, root_position_world)
    // Convert feet position from world space back to skeleton space for IK
    node_world_inv := linalg.matrix4_inverse(node_world_matrix)
    feet_world_h := linalg.Vector4f32 {
      leg.feet_position.x,
      leg.feet_position.y,
      leg.feet_position.z,
      1.0,
    }
    feet_skeleton_h := node_world_inv * feet_world_h
    feet_position_skeleton := feet_skeleton_h.xyz
    leg_bone_lengths := make([]f32, chain_len - 1, context.temp_allocator)
    for i in 0 ..< int(chain_len - 1) {
      bone_idx := leg_bone_indices[i + 1]
      leg_bone_lengths[i] = bone_lengths[bone_idx]
    }
    fk_transforms := make([]BoneTransform, chain_len, context.temp_allocator)
    for i in 0 ..< int(chain_len) {
      bone_idx := leg_bone_indices[i]
      fk_transforms[i] = world_transforms[bone_idx]
    }
    // Compute pole pointing upward (perpendicular to leg direction)
    // This makes the leg bend naturally with the "knee" pointing outward/upward
    leg_dir := feet_position_skeleton - root_position_skeleton
    up := [3]f32{0, 1, 0} // World up
    // Pole is positioned perpendicular to the leg direction, offset from the midpoint
    pole_offset := up - leg_dir * linalg.dot(up, leg_dir) / linalg.dot(leg_dir, leg_dir)
    mid_point := (root_position_skeleton + feet_position_skeleton) / 2.0
    pole := mid_point + linalg.normalize(pole_offset) * 2.0

    ik_target := IKTarget {
      bone_indices    = leg_bone_indices,
      bone_lengths    = leg_bone_lengths,
      target_position = feet_position_skeleton, // Use skeleton-space position for IK
      pole_vector     = pole,
      pole_weight     = 0.8, // Strong but not absolute pole influence
      max_iterations  = 10,
      tolerance       = 0.01,
      weight          = 1.0,
      enabled         = true,
    }
    fabrik_solve(world_transforms, ik_target)

    // Store debug info if enabled
    if debug_enabled && leg_idx < len(params.debug_info) {
      info := &params.debug_info[leg_idx]

      // Resize positions array if needed
      if len(info.positions) != int(chain_len) {
        delete(info.positions)
        info.positions = make([][3]f32, chain_len)
      }

      // Copy joint positions
      for i in 0 ..< int(chain_len) {
        bone_idx := leg_bone_indices[i]
        info.positions[i] = world_transforms[bone_idx].world_position
      }

      info.target = feet_position_skeleton
      info.pole = pole
      info.has_pole = true
    }
    for i in 0 ..< int(chain_len) {
      bone_idx := leg_bone_indices[i]
      ik_pos := world_transforms[bone_idx].world_position
      fk_pos := fk_transforms[i].world_position
      world_transforms[bone_idx].world_position = linalg.lerp(
        fk_pos,
        ik_pos,
        layer_weight,
      )
      ik_rot := world_transforms[bone_idx].world_rotation
      fk_rot := fk_transforms[i].world_rotation
      world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
        fk_rot,
        ik_rot,
        layer_weight,
      )
      scale := extract_scale(world_transforms[bone_idx].world_matrix)
      world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
        world_transforms[bone_idx].world_position,
        world_transforms[bone_idx].world_rotation,
        scale,
      )
    }
  }
}

single_bone_rotation_modifier_update :: proc(
  state: ^ProceduralState,
  params: ^SingleBoneRotationModifier,
  delta_time: f32,
  world_transforms: []BoneTransform,
  layer_weight: f32,
  bone_lengths: []f32,
) {
  bone_idx := params.bone_index
  // Apply the rotation as a local rotation override
  fk_rotation := world_transforms[bone_idx].world_rotation
  procedural_rotation := params.rotation * fk_rotation
  world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
    fk_rotation,
    procedural_rotation,
    layer_weight,
  )
  // Update world matrix
  scale := extract_scale(world_transforms[bone_idx].world_matrix)
  world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
    world_transforms[bone_idx].world_position,
    world_transforms[bone_idx].world_rotation,
    scale,
  )
}

extract_scale :: proc(m: matrix[4, 4]f32) -> [3]f32 {
  return [3]f32 {
    linalg.length(m[0].xyz),
    linalg.length(m[1].xyz),
    linalg.length(m[2].xyz),
  }
}

extract_z_axis :: proc(m: matrix[4, 4]f32) -> [3]f32 {
  return linalg.normalize(m[2].xyz)
}
