package animation

import "../geometry"
import "core:math"
import "core:math/linalg"

// IKBoneConstraint limits a bone; max_angle is (swing X, twist Y, swing Z) in radians
// about bone-local axes (Y is forward). Negative = unconstrained, zero = locked.
IKBoneConstraint :: struct {
  max_angle: [3]f32,
}

// ik_constraints_uniform builds a chain of constraints: bone 0 (root) gets `root_max`, bones 1..N-1 get `rest_max`.
// Caller owns the returned slice.
ik_constraints_uniform :: proc(
  chain_length: int,
  root_max: [3]f32,
  rest_max: [3]f32,
  allocator := context.allocator,
) -> []IKBoneConstraint {
  out := make([]IKBoneConstraint, chain_length, allocator)
  if chain_length == 0 do return out
  out[0] = IKBoneConstraint{max_angle = root_max}
  for i in 1 ..< chain_length {
    out[i] = IKBoneConstraint{max_angle = rest_max}
  }
  return out
}

// IKTargetSpace is the space of IK target and pole values: LOCAL is skeleton space,
// WORLD is converted each animator_update so the target stays fixed as the rig moves.
IKTargetSpace :: enum {
  LOCAL,
  WORLD,
}

// IKTarget is the FABRIK solver input (supports N bones, minimum 2).
IKTarget :: struct {
  bone_indices:    []u32, // All bones in chain from root to end (min 2 bones)
  bone_lengths:    []f32, // Cached bone lengths (len = bone_indices - 1)
  constraints:     []IKBoneConstraint, // Optional per-bone constraints (nil or len = chain length)
  target_position: [3]f32,
  pole_vector:     [3]f32, // Point the chain's non-root bones twist their X axis toward; the bend plane comes from the FK pose
  pole_weight:     f32, // Pole twist strength (0-1), ik_layer_create defaults to 1
  max_iterations:  int,
  tolerance:       f32, // Stop when end effector within this distance
  weight:          f32, // Blend weight (0-1), 1 = full IK, 0 = pure FK
  enabled:         bool,
  space:           IKTargetSpace, // Space target_position and pole_vector live in
}

// Clamp `dir` so its angular deviation from `fk_rot`'s forward axis (qy)
// stays within an elliptical cone defined by max_angle.x (swing toward bone-local X)
// and max_angle.z (swing toward bone-local Z). Direction is preserved when within bounds.
@(private = "file")
apply_swing_constraint :: proc(
  dir: [3]f32,
  fk_rot: quaternion128,
  max_x: f32,
  max_z: f32,
) -> [3]f32 {
  if max_x < 0 && max_z < 0 do return dir
  inv_fk := linalg.quaternion_inverse(fk_rot)
  local_dir := geometry.qmv(inv_fk, dir)
  // local_dir.y = cos(swing_angle), (local_dir.x, local_dir.z) is the swing axis direction.
  cos_swing := clamp(local_dir.y, -1.0, 1.0)
  swing_angle := math.acos(cos_swing)
  if swing_angle < 1e-5 do return dir
  xz_len := math.sqrt(local_dir.x * local_dir.x + local_dir.z * local_dir.z)
  if xz_len < 1e-6 do return dir
  sxz_x := local_dir.x / xz_len
  sxz_z := local_dir.z / xz_len
  // Effective limit at this swing direction. Treat negative (unconstrained) by replacing
  // with the full pi, so the other axis solely governs the bound.
  lim_x := max_x if max_x >= 0 else math.PI
  lim_z := max_z if max_z >= 0 else math.PI
  limit := math.sqrt(sxz_x * sxz_x * lim_x * lim_x + sxz_z * sxz_z * lim_z * lim_z)
  if swing_angle <= limit do return dir
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
  // delta_local = inv(fk) * delta_world * fk where delta_world = new_rot * inv(fk),
  // simplifies to inv(fk) * new_rot. Re-expresses the FK-to-new delta in fk's local frame.
  inv_fk := linalg.quaternion_inverse(fk_rot)
  delta_local := inv_fk * new_rot
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
  half := clamped_angle * 0.5
  new_twist_local := quaternion128{}
  new_twist_local.w = math.cos(half)
  new_twist_local.y = math.sin(half)
  old_twist_local := quaternion128{}
  old_twist_local.w = twist_w
  old_twist_local.y = twist_y
  swing_local := delta_local * linalg.quaternion_inverse(old_twist_local)
  new_delta_local := swing_local * new_twist_local
  // fk * new_delta_local = fk * (inv(fk) * clamped_new_rot) = clamped_new_rot.
  return fk_rot * new_delta_local
}

// Unit vector along `v`, or `fallback` when `v` is (near) zero length.
@(private = "file")
safe_dir :: #force_inline proc(v, fallback: [3]f32) -> [3]f32 {
  l2 := linalg.length2(v)
  return v / math.sqrt(l2) if l2 > 1e-12 else fallback
}

// FABRIK solver for N-bone IK chains (minimum 2 bones)
// Forward And Backward Reaching Inverse Kinematics
//
// Algorithm:
// 1. Forward pass: Starting from end effector, drag each joint toward target
// 2. Backward pass: Starting from root, restore root position.
// 3. Repeat until convergence or max iterations
// With constraints, the backward pass clamps each segment direction to the bone's
// cone, measured against its FK orientation carried by the parent's solved swing.
// When progress stalls the forward pass clamps too (using the latest backward
// pass's frames), so the chain can fold instead of sitting at a fixed point.
//
// `positions`/`rotations` hold the skeleton-space FK pose of every bone,
// indexed by bone. The chain's entries are overwritten with the solved pose,
// blended with the FK pose by `target.weight`.
@(private)
fabrik_solve :: proc(positions: [][3]f32, rotations: []quaternion128, target: IKTarget) {
  if !target.enabled || target.weight <= 0.0 do return
  chain_length := len(target.bone_indices)
  if chain_length < 2 do return
  for idx in target.bone_indices {
    if idx >= u32(len(positions)) || idx >= u32(len(rotations)) do return
  }
  bone_lengths := target.bone_lengths
  if len(bone_lengths) != chain_length - 1 do return
  constraints := target.constraints
  has_constraints := constraints != nil && len(constraints) == chain_length
  joints := make([][3]f32, chain_length, context.temp_allocator)
  fk_positions := make([][3]f32, chain_length, context.temp_allocator)
  fk_rotations := make([]quaternion128, chain_length, context.temp_allocator)
  fk_dirs := make([][3]f32, chain_length - 1, context.temp_allocator)
  for i in 0 ..< chain_length {
    bone_idx := target.bone_indices[i]
    joints[i] = positions[bone_idx]
    fk_positions[i] = positions[bone_idx]
    fk_rotations[i] = rotations[bone_idx]
  }
  frames := make([]quaternion128, chain_length, context.temp_allocator)
  copy(frames, fk_rotations)
  for i in 0 ..< chain_length - 1 {
    fk_dirs[i] = safe_dir(fk_positions[i + 1] - fk_positions[i], geometry.qy(fk_rotations[i]))
  }
  root_position := joints[0]
  target_pos := target.target_position
  total_length: f32 = 0
  for length in bone_lengths do total_length += length
  dist_to_target := linalg.distance(root_position, target_pos)
  if dist_to_target > total_length * 0.999 {
    // Unreachable: re-aim every segment from its own joint so a constrained
    // chain still curls toward the target.
    place_from_root(joints, target_pos, fk_dirs, fk_rotations, bone_lengths, constraints if has_constraints else nil, frames, aim = true)
  } else {
    iterations := target.max_iterations > 0 ? target.max_iterations : 10
    tolerance := target.tolerance > 0 ? target.tolerance : 0.001
    // Constraining the forward pass lets a chain fold where the plain pass stalls,
    // but its frames lag one iteration; switch passes whenever progress stops
    // and keep the closest result.
    constrain_forward := false
    best := make([][3]f32, chain_length, context.temp_allocator)
    best_dist_sq, prev_dist_sq := max(f32), max(f32)
    for _ in 0 ..< iterations {
      joints[chain_length - 1] = target_pos
      for i := chain_length - 2; i >= 0; i -= 1 {
        dir := safe_dir(joints[i + 1] - joints[i], fk_dirs[i])
        if constrain_forward {
          c := constraints[i]
          dir = apply_swing_constraint(dir, frames[i], c.max_angle.x, c.max_angle.z)
        }
        joints[i] = joints[i + 1] - dir * bone_lengths[i]
      }
      joints[0] = root_position
      place_from_root(joints, target_pos, fk_dirs, fk_rotations, bone_lengths, constraints if has_constraints else nil, frames, aim = false)
      end_dist_sq := linalg.length2(joints[chain_length - 1] - target_pos)
      if end_dist_sq < best_dist_sq {
        best_dist_sq = end_dist_sq
        copy(best, joints)
      }
      if end_dist_sq < tolerance * tolerance do break
      if has_constraints && end_dist_sq > prev_dist_sq * 0.999 do constrain_forward = !constrain_forward
      prev_dist_sq = end_dist_sq
    }
    copy(joints, best)
  }
  update_transforms_from_positions(
    positions,
    rotations,
    target.bone_indices,
    joints,
    fk_positions,
    fk_dirs,
    fk_rotations,
    target.pole_vector,
    target.pole_weight,
    constraints if has_constraints else nil,
  )
  if target.weight < 1 do blend_with_fk(positions, rotations, target.bone_indices, fk_positions, fk_rotations, target.weight)
}

// Backward FABRIK pass: walk from the root placing each joint one bone length
// along its segment direction. With `aim`, the direction is toward the target
// rather than toward the joint's current position. When `constraints` is
// non-nil, each direction is clamped against the bone's FK orientation carried
// by its parent's solved swing, so the limit cone follows the parent; that
// frame is stored in `frames` for the next forward pass.
@(private = "file")
place_from_root :: proc(
  joints: [][3]f32,
  target_pos: [3]f32,
  fk_dirs: [][3]f32,
  fk_rotations: []quaternion128,
  bone_lengths: []f32,
  constraints: []IKBoneConstraint,
  frames: []quaternion128,
  aim: bool,
) {
  parent_swing := linalg.QUATERNIONF32_IDENTITY
  for i in 0 ..< len(joints) - 1 {
    to := target_pos if aim else joints[i + 1]
    dir := safe_dir(to - joints[i], fk_dirs[i])
    if constraints != nil {
      c := constraints[i]
      dir = apply_swing_constraint(dir, parent_swing * fk_rotations[i], c.max_angle.x, c.max_angle.z)
    }
    frames[i] = parent_swing * fk_rotations[i]
    joints[i + 1] = joints[i] + dir * bone_lengths[i]
    parent_swing = linalg.quaternion_between_two_vector3(fk_dirs[i], dir)
  }
}

// Blend the solved chain toward its FK pose by `weight`: rotations slerp, and
// positions are rebuilt from the root so bone lengths are kept.
@(private = "file")
blend_with_fk :: proc(
  positions: [][3]f32,
  rotations: []quaternion128,
  bone_indices: []u32,
  fk_positions: [][3]f32,
  fk_rotations: []quaternion128,
  weight: f32,
) {
  for b, i in bone_indices {
    rotations[b] = linalg.quaternion_slerp(fk_rotations[i], rotations[b], weight)
  }
  positions[bone_indices[0]] = fk_positions[0]
  for i in 1 ..< len(bone_indices) {
    parent, b := bone_indices[i - 1], bone_indices[i]
    delta := rotations[parent] * linalg.quaternion_inverse(fk_rotations[i - 1])
    positions[b] = positions[parent] + geometry.qmv(delta, fk_positions[i] - fk_positions[i - 1])
  }
}

// Write the chain's solved joint positions and the matching rotations back
// into the pose. Uses swing-twist decomposition for pole-controlled twist.
// When `constraints` is non-nil, applies twist limit (max_angle.y) per bone,
// measured against the FK orientation carried by the parent's swing.
@(private = "file")
update_transforms_from_positions :: proc(
  positions: [][3]f32,
  rotations: []quaternion128,
  bone_indices: []u32,
  joints: [][3]f32,
  fk_positions: [][3]f32,
  fk_dirs: [][3]f32,
  fk_rotations: []quaternion128,
  pole_vector: [3]f32,
  pole_weight: f32,
  constraints: []IKBoneConstraint,
) {
  chain_length := len(bone_indices)
  has_pole := linalg.length2(pole_vector) > math.F32_EPSILON && pole_weight > 0
  last_swing := linalg.QUATERNIONF32_IDENTITY
  // Bones 0..chain_length-2: swing from segment (i, i+1). Last bone inherits last_swing.
  for i in 0 ..< chain_length - 1 {
    bone_idx := bone_indices[i]
    ik_dir := safe_dir(joints[i + 1] - joints[i], fk_dirs[i])
    swing := linalg.quaternion_between_two_vector3(fk_dirs[i], ik_dir)
    parent_swing := last_swing
    last_swing = swing
    new_rot := swing * fk_rotations[i]
    if has_pole && i > 0 {
      fk_perp := geometry.qx(fk_rotations[i])
      current_perp := geometry.qmv(swing, fk_perp)
      to_pole := pole_vector - joints[i]
      desired_perp := to_pole - ik_dir * linalg.dot(to_pole, ik_dir)
      perp_len := linalg.length(desired_perp)
      if perp_len > math.F32_EPSILON {
        desired_perp /= perp_len
        twist := linalg.quaternion_between_two_vector3(current_perp, desired_perp)
        // Twist after swing: twist rotates around ik_dir (new bone direction).
        interpolated_twist := linalg.quaternion_slerp(
          linalg.QUATERNIONF32_IDENTITY,
          twist,
          pole_weight,
        )
        new_rot = interpolated_twist * new_rot
      }
    }
    if constraints != nil {
      new_rot = apply_twist_constraint(new_rot, parent_swing * fk_rotations[i], constraints[i].max_angle.y)
    }
    positions[bone_idx] = joints[i]
    rotations[bone_idx] = new_rot
  }
  // Last bone: same swing as parent segment (no outgoing segment), so it has
  // no twist relative to its parent and needs no twist limit.
  last := chain_length - 1
  bone_idx := bone_indices[last]
  positions[bone_idx] = joints[last]
  rotations[bone_idx] = last_swing * fk_rotations[last]
}
