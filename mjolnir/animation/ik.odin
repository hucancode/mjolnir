package animation

import "core:math"
import "core:math/linalg"

// IKTargetSpace is the space of IK target and pole values: LOCAL is skeleton space,
// WORLD is converted each animator_update so the target stays fixed as the rig moves.
IKTargetSpace :: enum {
  LOCAL,
  WORLD,
}

// IKParams reaches a chain's last bone for `target`. Its layer's bones are the chain, root
// first, each bone the parent of the next (bone_chain); joint limits come from bone_limits.
IKParams :: struct {
  target:      [3]f32,
  pole:        [3]f32, // point the chain's bend (its middle joints) turns toward, about the root-to-target axis
  pole_weight: f32, // how far the bend turns toward the pole, 0-1
  space:       IKTargetSpace, // space target and pole live in
  iterations:  int, // 0 = 10
  tolerance:   f32, // stop when the end is this close to target; 0 = 0.001
}

@(private)
ik_apply :: proc(pose: Pose, bones: []u32, params: IKParams) {
  target, pole := params.target, params.pole
  if params.space == .WORLD do target, pole = to_model(pose, target), to_model(pose, pole)
  ik_solve(pose, bones, target, pole, params.pole_weight, params.iterations, params.tolerance)
}

// Clamp `dir` so its angular deviation from `fk_rot`'s forward axis (+Y)
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
  local_dir := linalg.mul(inv_fk, dir)
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
  return linalg.mul(fk_rot, clamped_local)
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

// ik_solve bends the chain `bones` (root first, each the parent of the next) so its last bone
// reaches `target`, all in skeleton space, within the pose's joint limits. The chain keeps its
// rest bone lengths; `pole` twists it (see IKParams). 0 iterations or tolerance = defaults.
ik_solve :: proc(
  pose: Pose,
  bones: []u32,
  target: [3]f32,
  pole: [3]f32 = {},
  pole_weight: f32 = 0,
  iterations: int = 10,
  tolerance: f32 = 0.001,
) {
  // FABRIK (Forward And Backward Reaching Inverse Kinematics):
  // 1. Forward pass: starting from the end effector, drag each joint toward the target.
  // 2. Backward pass: starting from the root, restore the root position.
  // 3. Repeat until convergence or max iterations.
  // With constraints, the backward pass clamps each segment direction to the bone's
  // cone, measured against its FK orientation carried by the parent's solved swing.
  // When progress stalls the forward pass clamps too (using the latest backward
  // pass's frames), so the chain can fold instead of sitting at a fixed point.
  positions, rotations := pose.positions, pose.rotations
  chain_length := len(bones)
  if chain_length < 2 do return
  for idx in bones do if int(idx) >= len(positions) do return
  bone_lengths := make([]f32, chain_length - 1, context.temp_allocator)
  for i in 1 ..< chain_length do bone_lengths[i - 1] = pose.lengths[bones[i]]
  constraints := make([]JointLimit, chain_length, context.temp_allocator)
  has_constraints := false
  for b, i in bones {
    constraints[i] = pose.limits[b] if int(b) < len(pose.limits) else JOINT_FREE
    has_constraints ||= constraints[i] != JOINT_FREE
  }
  joints := make([][3]f32, chain_length, context.temp_allocator)
  fk_positions := make([][3]f32, chain_length, context.temp_allocator)
  fk_rotations := make([]quaternion128, chain_length, context.temp_allocator)
  fk_dirs := make([][3]f32, chain_length - 1, context.temp_allocator)
  for i in 0 ..< chain_length {
    bone_idx := bones[i]
    joints[i] = positions[bone_idx]
    fk_positions[i] = positions[bone_idx]
    fk_rotations[i] = rotations[bone_idx]
  }
  frames := make([]quaternion128, chain_length, context.temp_allocator)
  copy(frames, fk_rotations)
  for i in 0 ..< chain_length - 1 {
    fk_dirs[i] = safe_dir(fk_positions[i + 1] - fk_positions[i], linalg.mul(fk_rotations[i], linalg.VECTOR3F32_Y_AXIS))
  }
  root_position := joints[0]
  target_pos := target
  total_length: f32 = 0
  for length in bone_lengths do total_length += length
  dist_to_target := linalg.distance(root_position, target_pos)
  // Start from the pole's bend plane so the constrained solve below keeps the limits.
  aim_bend_at_pole(joints, target_pos, pole, clamp(pole_weight, 0, 1))
  if dist_to_target > total_length * 0.999 {
    // Unreachable: re-aim every segment from its own joint so a constrained
    // chain still curls toward the target.
    place_from_root(joints, target_pos, fk_dirs, fk_rotations, bone_lengths, constraints if has_constraints else nil, frames, aim = true)
  } else {
    iterations := iterations if iterations > 0 else 10
    tolerance := tolerance if tolerance > 0 else 0.001
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
    bones,
    joints,
    fk_dirs,
    fk_rotations,
    constraints if has_constraints else nil,
  )
}

// Rotate the middle joints about the root-to-`end` axis so the chain's bend points toward `pole`.
// Bone lengths stay put. A chain with no bend, or a pole on the axis, is left alone.
@(private = "file")
aim_bend_at_pole :: proc(joints: [][3]f32, end, pole: [3]f32, weight: f32) {
  n := len(joints)
  if n < 3 || weight <= 0 || linalg.length2(pole) <= math.F32_EPSILON do return
  root := joints[0]
  axis_v := end - root
  if linalg.length2(axis_v) < 1e-12 do return
  axis := linalg.normalize(axis_v)
  perp :: proc(v, axis: [3]f32) -> [3]f32 {
    return v - axis * linalg.dot(v, axis)
  }
  bend: [3]f32
  for i in 1 ..< n - 1 do bend += perp(joints[i] - root, axis)
  want := perp(pole - root, axis)
  if linalg.length2(bend) < 1e-10 || linalg.length2(want) < 1e-10 do return
  bend, want = linalg.normalize(bend), linalg.normalize(want)
  q: quaternion128
  if linalg.dot(bend, want) < -0.9999 {
    q = linalg.quaternion_angle_axis(f32(math.PI), axis)
  } else {
    q = linalg.quaternion_between_two_vector3(bend, want)
  }
  q = linalg.quaternion_slerp(linalg.QUATERNIONF32_IDENTITY, q, weight)
  for i in 1 ..< n - 1 do joints[i] = root + linalg.mul(q, joints[i] - root)
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
  constraints: []JointLimit,
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

// Write the chain's solved joint positions and the matching rotations back
// into the pose. When `constraints` is non-nil, applies twist limit (max_angle.y)
// per bone, measured against the FK orientation carried by the parent's swing.
@(private = "file")
update_transforms_from_positions :: proc(
  positions: [][3]f32,
  rotations: []quaternion128,
  bone_indices: []u32,
  joints: [][3]f32,
  fk_dirs: [][3]f32,
  fk_rotations: []quaternion128,
  constraints: []JointLimit,
) {
  chain_length := len(bone_indices)
  last_swing := linalg.QUATERNIONF32_IDENTITY
  // Bones 0..chain_length-2: swing from segment (i, i+1). Last bone inherits last_swing.
  for i in 0 ..< chain_length - 1 {
    bone_idx := bone_indices[i]
    ik_dir := safe_dir(joints[i + 1] - joints[i], fk_dirs[i])
    swing := linalg.quaternion_between_two_vector3(fk_dirs[i], ik_dir)
    parent_swing := last_swing
    last_swing = swing
    new_rot := swing * fk_rotations[i]
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

// two_link solves a planar two-link chain of lengths l1 and l2 to reach `target`. a is the
// first link's angle from +x toward +y, b the second's turn off the first, folding toward -y
// (b <= 0). A target out of reach straightens or folds the chain toward it and reached is false.
two_link :: proc(l1, l2: f32, target: [2]f32) -> (a, b: f32, reached: bool) {
  r := linalg.length(target)
  reached = r <= l1 + l2 && r >= abs(l1 - l2)
  b = -math.acos(clamp((r * r - l1 * l1 - l2 * l2) / (2 * l1 * l2), -1, 1))
  a = math.atan2(target.y, target.x) - math.atan2(l2 * math.sin(b), l1 + l2 * math.cos(b))
  return
}
