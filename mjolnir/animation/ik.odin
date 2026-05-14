package animation

import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"

// Per-bone rotation constraint, relative to FK rest pose in bone-local frame.
// max_angle.x = max swing toward bone-local X axis (radians)
// max_angle.y = max twist around bone-local Y axis (bone forward)
// max_angle.z = max swing toward bone-local Z axis
// Swing limits (X,Z) combine into an elliptical cone constraining bone direction.
// Twist limit (Y) is applied to rotation around the bone's forward axis.
// A negative value means unconstrained on that axis. Zero means locked.
IKBoneConstraint :: struct {
  max_angle: [3]f32,
}

// Coordinate space for IK target/pole values stored in the layer.
// LOCAL : already in skeleton-local space. Solver consumes verbatim.
// WORLD : in world space. sample_layers converts to local each frame
//         using the current node world matrix, so the target stays fixed
//         in the world as the rigged node moves.
IKTargetSpace :: enum {
  LOCAL,
  WORLD,
}

// IK target for FABRIK solver (supports N bones, minimum 2)
IKTarget :: struct {
  bone_indices:    []u32, // All bones in chain from root to end (min 2 bones)
  bone_lengths:    []f32, // Cached bone lengths (len = bone_indices - 1)
  constraints:     []IKBoneConstraint, // Optional per-bone constraints (nil or len = bone_indices)
  target_position: [3]f32,
  pole_vector:     [3]f32, // Controls the bending plane
  pole_weight:     f32, // Pole influence strength (0-1), default 1.0
  max_iterations:  int,
  tolerance:       f32, // Stop when end effector within this distance
  weight:          f32, // Blend weight (0-1), 1 = full IK, 0 = pure FK
  enabled:         bool,
  space:           IKTargetSpace, // Space target_position and pole_vector live in
}

// Internal struct to store bone world transforms during IK solving
BoneTransform :: struct {
  world_position: [3]f32,
  world_rotation: quaternion128,
  world_matrix:   matrix[4, 4]f32,
}

// Clamp `dir_world` so its angular deviation from `fk_rot`'s forward axis (qy)
// stays within an elliptical cone defined by max_angle.x (swing toward bone-local X)
// and max_angle.z (swing toward bone-local Z). Direction is preserved when within bounds.
@(private = "file")
apply_swing_constraint :: proc(
  dir_world: [3]f32,
  fk_rot: quaternion128,
  max_x: f32,
  max_z: f32,
) -> [3]f32 {
  // Both axes unconstrained: nothing to clamp.
  if max_x < 0 && max_z < 0 do return dir_world
  // Convert direction into bone-local frame (rest orientation defines axes).
  inv_fk := linalg.quaternion_inverse(fk_rot)
  local_dir := geometry.qmv(inv_fk, dir_world)
  // local_dir.y = cos(swing_angle), (local_dir.x, local_dir.z) is the swing axis direction.
  cos_swing := clamp(local_dir.y, -1.0, 1.0)
  swing_angle := math.acos(cos_swing)
  if swing_angle < 1e-5 do return dir_world
  xz_len := math.sqrt(local_dir.x * local_dir.x + local_dir.z * local_dir.z)
  if xz_len < 1e-6 do return dir_world
  sxz_x := local_dir.x / xz_len
  sxz_z := local_dir.z / xz_len
  // Effective limit at this swing direction. Treat negative (unconstrained) by replacing
  // with the full pi, so the other axis solely governs the bound.
  lim_x := max_x if max_x >= 0 else math.PI
  lim_z := max_z if max_z >= 0 else math.PI
  limit := math.sqrt(sxz_x * sxz_x * lim_x * lim_x + sxz_z * sxz_z * lim_z * lim_z)
  if swing_angle <= limit do return dir_world
  new_xz_mag := math.sin(limit)
  new_y := math.cos(limit)
  clamped_local := [3]f32{sxz_x * new_xz_mag, new_y, sxz_z * new_xz_mag}
  return geometry.qmv(fk_rot, clamped_local)
}

// Clamp twist rotation of `new_rot` around `fk_rot`'s forward axis. Returns a rotation
// whose twist-from-fk component is bounded to ±max_twist while preserving the swing.
@(private = "file")
apply_twist_constraint :: proc(
  new_rot: quaternion128,
  fk_rot: quaternion128,
  max_twist: f32,
) -> quaternion128 {
  if max_twist < 0 do return new_rot
  inv_fk := linalg.quaternion_inverse(fk_rot)
  // delta in fk-local frame: how new_rot deviates from rest.
  delta_world := new_rot * inv_fk
  delta_local := inv_fk * delta_world * fk_rot
  // Swing-twist decomposition along local Y.
  // Twist quaternion has zero X and Z components (axis aligned with Y).
  ty := delta_local.y
  tw := delta_local.w
  twist_mag := math.sqrt(ty * ty + tw * tw)
  if twist_mag < 1e-6 do return new_rot
  inv_mag := 1.0 / twist_mag
  twist_y := ty * inv_mag
  twist_w := tw * inv_mag
  twist_angle := 2.0 * math.atan2(twist_y, twist_w)
  if twist_angle > math.PI do twist_angle -= 2.0 * math.PI
  if twist_angle < -math.PI do twist_angle += 2.0 * math.PI
  clamped_angle := clamp(twist_angle, -max_twist, max_twist)
  if math.abs(clamped_angle - twist_angle) < 1e-5 do return new_rot
  // Rebuild twist quaternion.
  half := clamped_angle * 0.5
  new_twist_local := quaternion128{}
  new_twist_local.w = math.cos(half)
  new_twist_local.y = math.sin(half)
  // Swing = delta_local * conj(twist_local)
  old_twist_local := quaternion128{}
  old_twist_local.w = twist_w
  old_twist_local.y = twist_y
  swing_local := delta_local * linalg.quaternion_inverse(old_twist_local)
  new_delta_local := swing_local * new_twist_local
  new_delta_world := fk_rot * new_delta_local * inv_fk
  return new_delta_world * fk_rot
}

// FABRIK solver for N-bone IK chains (minimum 2 bones)
// Forward And Backward Reaching Inverse Kinematics
//
// Algorithm:
// 1. Forward pass: Starting from end effector, drag each joint toward target
// 2. Backward pass: Starting from root, restore root position. Each segment direction
//    is optionally constrained relative to its FK rest before placing the next joint.
// 3. Repeat until convergence or max iterations
//
// Expects world_transforms to contain FK-computed world transforms for all bones
// Modifies transforms for all bones in the chain to reach the target.
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
  constraints := target.constraints
  has_constraints := constraints != nil && len(constraints) == chain_length
  // Allocate temporary positions for the chain
  positions := make([][3]f32, chain_length, context.temp_allocator)
  // Cache FK rotations and positions for constraint reference.
  fk_rotations := make([]quaternion128, chain_length, context.temp_allocator)
  for i in 0 ..< chain_length {
    bone_idx := target.bone_indices[i]
    positions[i] = world_transforms[bone_idx].world_position
    fk_rotations[i] = world_transforms[bone_idx].world_rotation
  }
  root_position := positions[0]
  target_pos := target.target_position
  total_length: f32 = 0
  for length in bone_lengths do total_length += length
  // Check if target is reachable
  dist_to_target := linalg.distance(root_position, target_pos)
  if dist_to_target > total_length * 0.999 {
    // Target unreachable, stretch toward it (constraints still respected).
    direction := linalg.normalize(target_pos - root_position)
    positions[0] = root_position
    for i in 0 ..< chain_length - 1 {
      dir := direction
      if has_constraints {
        c := constraints[i]
        dir = apply_swing_constraint(dir, fk_rotations[i], c.max_angle.x, c.max_angle.z)
      }
      positions[i + 1] = positions[i] + dir * bone_lengths[i]
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
      // Backward pass: restore root and drag forward (constraints applied per segment)
      positions[0] = root_position
      for i in 0 ..< chain_length - 1 {
        dir := linalg.normalize(positions[i + 1] - positions[i])
        if has_constraints {
          c := constraints[i]
          dir = apply_swing_constraint(dir, fk_rotations[i], c.max_angle.x, c.max_angle.z)
        }
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
    fk_rotations,
    target.pole_vector,
    target.pole_weight,
    constraints if has_constraints else nil,
  )
}

// Update bone transforms (positions and rotations) from solved positions
// Uses swing-twist decomposition for pole-controlled twist.
// When `constraints` is non-nil, applies twist limit (max_angle.y) per bone.
update_transforms_from_positions :: proc(
  world_transforms: []BoneTransform,
  bone_indices: []u32,
  positions: [][3]f32,
  fk_rotations: []quaternion128,
  pole_vector: [3]f32,
  pole_weight: f32,
  constraints: []IKBoneConstraint,
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
    swing := linalg.quaternion_between_two_vector3(fk_dir, ik_dir)
    new_rot: quaternion128
    if has_pole && i > 0 {
      fk_rotation := world_transforms[bone_idx].world_rotation
      fk_perp := geometry.qx(fk_rotation)
      current_perp := geometry.qmv(swing, fk_perp)
      to_pole := pole_vector - positions[i]
      desired_perp := to_pole - ik_dir * linalg.dot(to_pole, ik_dir)
      perp_len := linalg.length(desired_perp)
      if perp_len > math.F32_EPSILON {
        desired_perp /= perp_len
        twist := linalg.quaternion_between_two_vector3(current_perp, desired_perp)
        // Apply twist AFTER swing: twist rotates around ik_dir (the new bone direction),
        // so swing must be applied first to establish that direction.
        interpolated_twist := linalg.quaternion_slerp(
          linalg.QUATERNIONF32_IDENTITY,
          twist,
          pole_weight,
        )
        new_rot = interpolated_twist * swing * world_transforms[bone_idx].world_rotation
      } else {
        new_rot = swing * world_transforms[bone_idx].world_rotation
      }
    } else {
      new_rot = swing * world_transforms[bone_idx].world_rotation
    }
    if constraints != nil {
      new_rot = apply_twist_constraint(new_rot, fk_rotations[i], constraints[i].max_angle.y)
    }
    world_transforms[bone_idx].world_rotation = new_rot
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
      new_rot := delta_rotation * world_transforms[bone_idx].world_rotation
      if constraints != nil {
        new_rot = apply_twist_constraint(new_rot, fk_rotations[i], constraints[i].max_angle.y)
      }
      world_transforms[bone_idx].world_rotation = new_rot
    }
    world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
      world_transforms[bone_idx].world_position,
      world_transforms[bone_idx].world_rotation,
      [3]f32{1.0, 1.0, 1.0},
    )
  }
}
