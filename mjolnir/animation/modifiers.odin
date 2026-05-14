package animation

import "core:math"
import "core:math/linalg"

// Per-bone state for tail animation
// position_world lags parent's tip via spring in true world space.
// Bone orientation is derived in pass 2 by aiming at child's lagged position.
TailBone :: struct {
  position_world:    [3]f32, // World-space bone root (state, lags FK)
  position_velocity: [3]f32, // Position velocity (inertia)
  is_initialized:    bool,
}

TailModifier :: struct {
  // 0..1, higher = stiffer spring = faster catch-up, faster oscillation
  propagation_speed: f32,
  // Damping ratio: 1 = critical (no overshoot), 0 = undamped, <0 grows, >1 overdamped
  damping:           f32,
  // If true, bones may stretch (pure spring). If false, distance to parent is
  // clamped to bone_length each frame (rigid hinge chain).
  stretch:           bool,
  bones:             []TailBone,
}

// Max spring stiffness mapped from propagation_speed = 1.
// Higher = snappier and faster oscillations.
TAIL_MAX_STIFFNESS :: f32(200.0)

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
  constraints:   [][]IKBoneConstraint, // Optional per-leg constraints (nil or len = legs)
  debug_info:    []IKDebugInfo, // Debug info for each leg (allocated if debug enabled)
}

Modifier :: union {
  TailModifier,
  PathModifier,
  SpiderLegModifier,
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
  node_world_matrix: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) {
  chain_length := len(state.bone_indices)
  if chain_length < 2 do return
  if len(params.bones) != chain_length do return
  if bone_lengths == nil do return

  node_world_inv := linalg.matrix4_inverse(node_world_matrix)

  to_world :: proc(m: matrix[4, 4]f32, p: [3]f32) -> [3]f32 {
    h := m * linalg.Vector4f32{p.x, p.y, p.z, 1.0}
    return h.xyz
  }

  stiffness := TAIL_MAX_STIFFNESS * clamp(params.propagation_speed, 0.0, 1.0)
  damping_coeff := 2.0 * math.sqrt(stiffness) * params.damping

  // Pass 1: spring-damp each child bone's world position toward its parent's
  // FK tip in world space. State stored in world coords so node translation
  // and FK rotation both produce drag through the chain.
  for i in 1 ..< chain_length {
    bone_idx := state.bone_indices[i]
    parent_idx := state.bone_indices[i - 1]
    bone_state := &params.bones[i]
    bone_length := bone_lengths[bone_idx]

    parent_pos_world := to_world(
      node_world_matrix,
      world_transforms[parent_idx].world_position,
    )
    parent_up_world := linalg.normalize(
      (node_world_matrix *
        linalg.Vector4f32 {
            world_transforms[parent_idx].world_matrix[1].x,
            world_transforms[parent_idx].world_matrix[1].y,
            world_transforms[parent_idx].world_matrix[1].z,
            0.0,
          }).xyz,
    )
    parent_tip_world := parent_pos_world + parent_up_world * bone_length

    if !bone_state.is_initialized {
      bone_state.position_world = parent_tip_world
      bone_state.is_initialized = true
    }

    pos_spring := (parent_tip_world - bone_state.position_world) * stiffness
    pos_damp := -bone_state.position_velocity * damping_coeff
    bone_state.position_velocity += (pos_spring + pos_damp) * delta_time
    bone_state.position_world += bone_state.position_velocity * delta_time

    // Rigid hinge: pin position to bone_length distance from parent.
    if !params.stretch {
      delta := bone_state.position_world - parent_pos_world
      d := linalg.length(delta)
      if d > 0.001 {
        bone_state.position_world =
          parent_pos_world + (delta / d) * bone_length
        // Remove the radial component of velocity to avoid spring fighting
        // the constraint each frame.
        radial := delta / d
        radial_speed := linalg.dot(bone_state.position_velocity, radial)
        bone_state.position_velocity -= radial * radial_speed
      }
    }

    lagged_pos_skeleton := to_world(node_world_inv, bone_state.position_world)
    world_transforms[bone_idx].world_position = linalg.lerp(
      world_transforms[bone_idx].world_position,
      lagged_pos_skeleton,
      layer_weight,
    )
  }

  // Pass 2: orient each parent bone toward its child's (lagged) position.
  // Last bone keeps FK rotation since it has no child to aim at.
  for i in 0 ..< chain_length - 1 {
    bone_idx := state.bone_indices[i]
    child_idx := state.bone_indices[i + 1]

    bone_direction :=
      world_transforms[child_idx].world_position -
      world_transforms[bone_idx].world_position
    if linalg.length(bone_direction) < 0.001 do continue

    bone_up := linalg.normalize(world_transforms[bone_idx].world_matrix[1].xyz)
    target_rotation := linalg.quaternion_between_two_vector3(
      bone_up,
      linalg.normalize(bone_direction),
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

  // Last bone: aim along the direction from its parent to itself so it
  // continues the chain instead of snapping back to FK orientation.
  last_idx := state.bone_indices[chain_length - 1]
  prev_idx := state.bone_indices[chain_length - 2]
  last_direction :=
    world_transforms[last_idx].world_position -
    world_transforms[prev_idx].world_position
  if linalg.length(last_direction) >= 0.001 {
    bone_up := linalg.normalize(world_transforms[last_idx].world_matrix[1].xyz)
    target_rotation := linalg.quaternion_between_two_vector3(
      bone_up,
      linalg.normalize(last_direction),
    )
    procedural_rotation :=
      target_rotation * world_transforms[last_idx].world_rotation
    world_transforms[last_idx].world_rotation = linalg.quaternion_slerp(
      world_transforms[last_idx].world_rotation,
      procedural_rotation,
      layer_weight,
    )
  }
  scale := extract_scale(world_transforms[last_idx].world_matrix)
  world_transforms[last_idx].world_matrix = linalg.matrix4_from_trs(
    world_transforms[last_idx].world_position,
    world_transforms[last_idx].world_rotation,
    scale,
  )
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

    leg_constraints: []IKBoneConstraint
    if params.constraints != nil && leg_idx < len(params.constraints) {
      leg_constraints = params.constraints[leg_idx]
    }
    ik_target := IKTarget {
      bone_indices    = leg_bone_indices,
      bone_lengths    = leg_bone_lengths,
      constraints     = leg_constraints,
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
