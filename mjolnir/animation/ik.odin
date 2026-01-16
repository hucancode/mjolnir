package animation

import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"

// IK target for FABRIK solver (supports N bones, minimum 2)
IKTarget :: struct {
  bone_indices:    []u32, // All bones in chain from root to end (min 2 bones)
  bone_lengths:    []f32, // Cached bone lengths (len = bone_indices - 1)
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
fabrik_solve :: proc(world_transforms: []BoneTransform, target: IKTarget) {
  if !target.enabled || target.weight <= 0.0 do return
  chain_length := len(target.bone_indices)
  if chain_length < 2 do return
  // Validate all indices
  for idx in target.bone_indices {
    if idx >= u32(len(world_transforms)) do return
  }
  bone_lengths := target.bone_lengths
  if len(bone_lengths) != chain_length - 1 do return
  // Allocate temporary positions for the chain
  positions := make([][3]f32, chain_length, context.temp_allocator)
  // Extract initial positions from world transforms
  for i in 0 ..< chain_length {
    bone_idx := target.bone_indices[i]
    positions[i] = world_transforms[bone_idx].world_position
  }
  root_position := positions[0]
  target_pos := target.target_position
  total_length: f32 = 0
  for length in bone_lengths do total_length += length
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
      // Check convergence (using squared distance avoids sqrt)
      end_dist_sq := linalg.length2(positions[chain_length - 1] - target_pos)
      if end_dist_sq < tolerance * tolerance {
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
  root := positions[0]
  end := positions[chain_length - 1]
  to_end := end - root
  line_dir := linalg.normalize(to_end)
  // For each internal joint (not root or end)
  if linalg.length2(to_end) < math.F32_EPSILON do return
  // Pre-compute pole direction once (hoist out of loop)
  pole_dir_unnorm := pole_vector - root
  pole_dir_valid := linalg.length2(pole_dir_unnorm) > math.F32_EPSILON
  pole_dir_from_root := pole_dir_valid ? linalg.normalize(pole_dir_unnorm) : line_dir

  for i in 1 ..< chain_length - 1 {
    to_joint := positions[i] - root
    projection_dist := linalg.dot(to_joint, line_dir)
    projection_point := root + line_dir * projection_dist

    // Current perpendicular offset
    offset := positions[i] - projection_point
    offset_length_sq := linalg.length2(offset)

    // Handle edge case: joint on the line (branchless using max)
    is_on_line := offset_length_sq < math.F32_EPSILON
    when_on_line := linalg.normalize(
      pole_dir_from_root - line_dir * linalg.dot(pole_dir_from_root, line_dir),
    )
    offset = is_on_line ? when_on_line : offset
    offset_length_sq = max(offset_length_sq, 0.01)

    // Desired offset direction toward pole
    to_pole := pole_vector - projection_point
    pole_offset := to_pole - line_dir * linalg.dot(to_pole, line_dir)
    pole_offset_len_sq := linalg.length2(pole_offset)

    // Branchless: compute everything, use result only if valid
    valid_pole := pole_offset_len_sq > math.F32_EPSILON
    inv_pole_len := valid_pole ? 1.0 / math.sqrt(pole_offset_len_sq) : 1.0
    pole_dir := pole_offset * inv_pole_len
    inv_offset_len := 1.0 / math.sqrt(offset_length_sq)
    current_dir := offset * inv_offset_len
    new_offset := linalg.normalize(linalg.lerp(current_dir, pole_dir, 0.5))

    // Update position (branchless conditional)
    new_pos := projection_point + new_offset * math.sqrt(offset_length_sq)
    positions[i] = valid_pole ? new_pos : positions[i]
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
  // Process all bones except the last
  for i in 0 ..< chain_length - 1 {
    bone_idx := bone_indices[i]
    world_transforms[bone_idx].world_position = positions[i]
    fk_dir := fk_positions[i + 1] - fk_positions[i]
    ik_dir := positions[i + 1] - positions[i]
    delta_rotation := linalg.quaternion_between_two_vector3(fk_dir, ik_dir)
    world_transforms[bone_idx].world_rotation =
      delta_rotation * world_transforms[bone_idx].world_rotation
    // IMPORTANT: this algorithm do a deliberate assumption that all scale are 1.0, avoid costly scale computation
    // If non-uniform scaling is needed, extract scale once before the loop
    world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
      world_transforms[bone_idx].world_position,
      world_transforms[bone_idx].world_rotation,
      [3]f32{1.0, 1.0, 1.0},
    )
  }
  // Process last bone separately
  if chain_length >= 1 {
    i := chain_length - 1
    bone_idx := bone_indices[i]
    world_transforms[bone_idx].world_position = positions[i]
    // Last bone: orient in same direction as incoming bone segment
    if chain_length >= 2 {
      fk_dir := fk_positions[i] - fk_positions[i - 1]
      ik_dir := positions[i] - positions[i - 1]
      delta_rotation := linalg.quaternion_between_two_vector3(fk_dir, ik_dir)
      world_transforms[bone_idx].world_rotation =
        delta_rotation * world_transforms[bone_idx].world_rotation
    }
    world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
      world_transforms[bone_idx].world_position,
      world_transforms[bone_idx].world_rotation,
      [3]f32{1.0, 1.0, 1.0},
    )
  }
}
