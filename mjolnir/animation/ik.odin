package animation

import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"

// IK target for FABRIK solver (supports N bones, minimum 2)
IKTarget :: struct {
  bone_indices:    []u32, // All bones in chain from root to end (min 2 bones)
  target_position: [3]f32,
  pole_vector:     [3]f32, // Controls the bending plane
  max_iterations:  int,
  tolerance:       f32, // Stop when end effector within this distance
  weight:          f32, // Blend weight (0-1), 1 = full IK, 0 = pure FK
  enabled:         bool,
}

// Internal struct to store bone world transforms during IK solving
BoneTransform :: struct {
  world_position: [3]f32,
  world_rotation: quaternion128,
  world_matrix:   matrix[4, 4]f32,
}

// FABRIK solver for N-bone IK chains (minimum 2 bones)
// Forward And Backward Reaching Inverse Kinematics
//
// Algorithm:
// 1. Forward pass: Starting from end effector, drag each joint toward target
// 2. Backward pass: Starting from root, restore root position and propagate forward
// 3. Repeat until convergence or max iterations
//
// Expects world_transforms to contain FK-computed world transforms for all bones
// Modifies transforms for all bones in the chain to reach the target
fabrik_solve :: proc(
  world_transforms: []BoneTransform,
  target: IKTarget,
  bone_lengths: []f32,
) {
  if !target.enabled || target.weight <= 0.0 {
    return
  }
  chain_length := len(target.bone_indices)
  if chain_length < 2 {
    return
  }
  // Validate all indices
  for idx in target.bone_indices {
    if idx >= u32(len(world_transforms)) {
      return
    }
  }
  if len(bone_lengths) != chain_length - 1 {
    return
  }
  // Allocate temporary positions for the chain
  positions := make([][3]f32, chain_length, context.temp_allocator)
  // Extract initial positions from world transforms
  for i in 0 ..< chain_length {
    bone_idx := target.bone_indices[i]
    positions[i] = world_transforms[bone_idx].world_position
  }
  root_position := positions[0]
  target_pos := target.target_position
  // Compute total chain length
  total_length: f32 = 0
  for length in bone_lengths {
    total_length += length
  }
  // Check if target is reachable
  dist_to_target := linalg.distance(root_position, target_pos)
  if dist_to_target > total_length * 0.999 {
    // Target unreachable, stretch toward it
    direction := linalg.normalize(target_pos - root_position)
    positions[0] = root_position
    for i in 1 ..< chain_length {
      positions[i] = positions[i - 1] + direction * bone_lengths[i - 1]
    }
  } else {
    // Target reachable, iterate FABRIK
    iterations := target.max_iterations > 0 ? target.max_iterations : 10
    tolerance := target.tolerance > 0 ? target.tolerance : 0.001
    for _ in 0 ..< iterations {
      // Forward pass: drag from end to root
      positions[chain_length - 1] = target_pos
      for i := chain_length - 2; i >= 0; i -= 1 {
        dir := linalg.normalize(positions[i] - positions[i + 1])
        positions[i] = positions[i + 1] + dir * bone_lengths[i]
      }
      // Backward pass: restore root and drag forward
      positions[0] = root_position
      for i in 0 ..< chain_length - 1 {
        dir := linalg.normalize(positions[i + 1] - positions[i])
        positions[i + 1] = positions[i] + dir * bone_lengths[i]
      }
      // Check convergence
      end_dist := linalg.distance(positions[chain_length - 1], target_pos)
      if end_dist < tolerance {
        break
      }
    }
  }
  // Apply pole vector constraint
  if linalg.length2(target.pole_vector) > math.F32_EPSILON {
    apply_pole_constraint(positions[:], target.pole_vector, bone_lengths)
  }
  // Update world transforms from solved positions
  update_transforms_from_positions(
    world_transforms,
    target.bone_indices,
    positions[:],
    target.target_position,
  )
}

// Apply pole vector constraint to bend the chain toward the pole
apply_pole_constraint :: proc(
  positions: [][3]f32,
  pole_vector: [3]f32,
  bone_lengths: []f32,
) {
  chain_length := len(positions)
  if chain_length < 3 {
    return
  }
  // For each internal joint (not root or end)
  for i in 1 ..< chain_length - 1 {
    root := positions[0]
    end := positions[chain_length - 1]
    to_end := end - root
    if linalg.length2(to_end) < math.F32_EPSILON {
      continue
    }
    line_dir := linalg.normalize(to_end)
    to_joint := positions[i] - root
    projection_dist := linalg.dot(to_joint, line_dir)
    projection_point := root + line_dir * projection_dist
    // Current perpendicular offset
    offset := positions[i] - projection_point
    offset_length_sq := linalg.length2(offset)
    if offset_length_sq < math.F32_EPSILON {
      // Joint on the line, use pole to create offset
      pole_dir := linalg.normalize(pole_vector - root)
      offset = linalg.normalize(
        pole_dir - line_dir * linalg.dot(pole_dir, line_dir),
      )
      offset_length_sq = 0.01
    }
    // Desired offset direction toward pole
    to_pole := pole_vector - projection_point
    pole_offset := to_pole - line_dir * linalg.dot(to_pole, line_dir)
    if linalg.length2(pole_offset) > math.F32_EPSILON {
      pole_dir := linalg.normalize(pole_offset)
      current_dir := linalg.normalize(offset)
      new_offset := linalg.normalize(linalg.lerp(current_dir, pole_dir, 0.5))
      positions[i] =
        projection_point + new_offset * math.sqrt(offset_length_sq)
    }
  }
  // Re-enforce bone lengths after pole constraint
  for i in 1 ..< chain_length {
    dir := linalg.normalize(positions[i] - positions[i - 1])
    positions[i] = positions[i - 1] + dir * bone_lengths[i - 1]
  }
}

// Update bone transforms (positions and rotations) from solved positions
update_transforms_from_positions :: proc(
  world_transforms: []BoneTransform,
  bone_indices: []u32,
  positions: [][3]f32,
  target_position: [3]f32,
) {
  chain_length := len(bone_indices)
  // Save original FK positions before we start modifying them
  fk_positions := make([][3]f32, chain_length, context.temp_allocator)
  for i in 0 ..< chain_length {
    bone_idx := bone_indices[i]
    fk_positions[i] = world_transforms[bone_idx].world_position
  }
  for i in 0 ..< chain_length {
    bone_idx := bone_indices[i]
    // Update position
    world_transforms[bone_idx].world_position = positions[i]
    // Update rotation to point toward next bone
    if i < chain_length - 1 {
      // Get original FK direction
      fk_dir := linalg.normalize(fk_positions[i + 1] - fk_positions[i])
      // Get IK direction
      ik_dir := linalg.normalize(positions[i + 1] - positions[i])
      delta_rotation := linalg.quaternion_between_two_vector3(fk_dir, ik_dir)
      world_transforms[bone_idx].world_rotation =
        delta_rotation * world_transforms[bone_idx].world_rotation
    } else if chain_length >= 2 {
      // Last bone: orient in same direction as incoming bone segment
      // This makes the bone "point toward" the direction it reached
      // Original direction from previous to current (in FK)
      fk_dir := linalg.normalize(fk_positions[i] - fk_positions[i - 1])
      // IK direction from previous to current
      ik_dir := linalg.normalize(positions[i] - positions[i - 1])
      delta_rotation := linalg.quaternion_between_two_vector3(fk_dir, ik_dir)
      world_transforms[bone_idx].world_rotation =
        delta_rotation * world_transforms[bone_idx].world_rotation
    }
    // Update matrix
    t := geometry.decompose_matrix(world_transforms[bone_idx].world_matrix)
    world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
      world_transforms[bone_idx].world_position,
      world_transforms[bone_idx].world_rotation,
      t.scale,
    )
  }
}
