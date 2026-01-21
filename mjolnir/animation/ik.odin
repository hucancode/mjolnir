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
  pole_weight:     f32, // Pole influence strength (0-1), default 1.0
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
  // Update world transforms from solved positions (with pole-based twist control)
  update_transforms_from_positions(
    world_transforms,
    target.bone_indices,
    positions[:],
    target.pole_vector,
    target.pole_weight,
  )
}

// Update bone transforms (positions and rotations) from solved positions
// Uses swing-twist decomposition for pole-controlled twist
update_transforms_from_positions :: proc(
  world_transforms: []BoneTransform,
  bone_indices: []u32,
  positions: [][3]f32,
  pole_vector: [3]f32,
  pole_weight: f32,
) {
  chain_length := len(bone_indices)
  // Save original FK positions before we start modifying them
  fk_positions := make([][3]f32, chain_length, context.temp_allocator)
  for i in 0 ..< chain_length {
    bone_idx := bone_indices[i]
    fk_positions[i] = world_transforms[bone_idx].world_position
  }

  has_pole := linalg.length2(pole_vector) > math.F32_EPSILON && pole_weight > 0

  // Process all bones except the last
  for i in 0 ..< chain_length - 1 {
    bone_idx := bone_indices[i]
    world_transforms[bone_idx].world_position = positions[i]

    fk_dir := linalg.normalize(fk_positions[i + 1] - fk_positions[i])
    ik_dir := linalg.normalize(positions[i + 1] - positions[i])

    // Swing: align bone direction
    swing := linalg.quaternion_between_two_vector3(fk_dir, ik_dir)

    delta_rotation: quaternion128
    if has_pole && i > 0 && i < chain_length - 1 {
      // Internal bones: apply pole-controlled twist

      // Get FK bone's perpendicular axis (local X transformed to world)
      fk_rotation := world_transforms[bone_idx].world_rotation
      fk_perp := geometry.qmv(fk_rotation, [3]f32{1, 0, 0})

      // Apply swing to get current perpendicular
      current_perp := geometry.qmv(swing, fk_perp)

      // Compute desired perpendicular from pole
      to_pole := pole_vector - positions[i]
      desired_perp := to_pole - ik_dir * linalg.dot(to_pole, ik_dir)
      perp_len := linalg.length(desired_perp)

      if perp_len > math.F32_EPSILON {
        desired_perp /= perp_len

        // Compute twist rotation
        twist := linalg.quaternion_between_two_vector3(current_perp, desired_perp)

        // Blend twist based on pole_weight
        blended_twist := linalg.quaternion_slerp(
          linalg.QUATERNIONF32_IDENTITY,
          twist,
          pole_weight,
        )

        // Combine: swing then twist
        delta_rotation = blended_twist * swing
      } else {
        delta_rotation = swing
      }
    } else {
      // Root/end bones or no pole: just swing
      delta_rotation = swing
    }

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
      fk_dir := linalg.normalize(fk_positions[i] - fk_positions[i - 1])
      ik_dir := linalg.normalize(positions[i] - positions[i - 1])
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
