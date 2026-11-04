package animation

import "core:math"
import "core:math/linalg"

// IKTargetSpace is the space of IK target and pole values: LOCAL is skeleton space,
// WORLD is converted each animator_update so the target stays fixed as the rig moves.
IKTargetSpace :: enum {
  LOCAL,
  WORLD,
}

// IKParams reaches a chain's end for `target`. Its layer's bones are the chain, root first, each
// bone the parent of the next (bone_chain); joint limits come from bone_limits.
IKParams :: struct {
  target:      [3]f32,
  pole:        [3]f32, // point the chain's bend turns toward
  pole_weight: f32, // free chains: how far the bend turns toward the pole, 0-1; limited ones draw their middle toward it when > 0
  space:       IKTargetSpace, // space target and pole live in
  iterations:  int, // 0 = 10
  tolerance:   f32, // stop this close to target; 0 = 0.001
  end:         [3]f32, // the point that reaches, in the last bone's frame (a sole, a palm); 0 = the last bone itself
  ends:        u32, // how many bones at the chain's end are the end's own joints (an ankle, a wrist): they don't reach
  hold:        bool, // the end's own joints turn to keep its facing from before the solve (a planted foot); else they keep their turns
  middle:      u32, // limited chains: index in the chain of the joint the pole places (ik_chain_middle); 0 = none
}

@(private)
ik_apply :: proc(pose: Pose, bones: []u32, params: IKParams) {
  p := params
  if p.space == .WORLD do p.target, p.pole = to_model(pose, p.target), to_model(pose, p.pole)
  ik_solve(pose, bones, p)
}

// ik_solve bends the chain `bones` (root first, each the parent of the next) so its end reaches
// params.target, all in skeleton space (params.space is ignored), keeping every bone within its
// joint limits. A chain of free bones reaching with its last bone is solved by FABRIK in
// skeleton space; any other (a joint limit, an `end` point, end joints) by damped
// least squares over its joints' turns (limited_reach), which needs the pose's local and rest
// transforms and scales.
ik_solve :: proc(pose: Pose, bones: []u32, params: IKParams) {
  if len(bones) < 2 do return
  for idx in bones do if int(idx) >= len(pose.positions) do return
  if params.ends == 0 && params.end == 0 && !limited(pose, bones) {
    fabrik(pose, bones, params)
    return
  }
  limited_reach(pose, bones, params)
}

// Unit vector along `v`, or `fallback` when `v` is (near) zero length.
@(private = "file")
safe_dir :: #force_inline proc(v, fallback: [3]f32) -> [3]f32 {
  l2 := linalg.length2(v)
  return v / math.sqrt(l2) if l2 > 1e-12 else fallback
}

// FABRIK (Forward And Backward Reaching Inverse Kinematics) over a free chain:
// 1. Forward pass: starting from the end effector, drag each joint toward the target.
// 2. Backward pass: starting from the root, restore the root position.
// 3. Repeat until convergence or max iterations.
@(private = "file")
fabrik :: proc(pose: Pose, bones: []u32, params: IKParams) {
  positions, rotations := pose.positions, pose.rotations
  chain_length := len(bones)
  bone_lengths := make([]f32, chain_length - 1, context.temp_allocator)
  for i in 1 ..< chain_length do bone_lengths[i - 1] = pose.lengths[bones[i]]
  joints := make([][3]f32, chain_length, context.temp_allocator)
  fk_rotations := make([]quaternion128, chain_length, context.temp_allocator)
  fk_dirs := make([][3]f32, chain_length - 1, context.temp_allocator)
  for i in 0 ..< chain_length {
    joints[i] = positions[bones[i]]
    fk_rotations[i] = rotations[bones[i]]
  }
  for i in 0 ..< chain_length - 1 {
    fk_dirs[i] = safe_dir(joints[i + 1] - joints[i], linalg.mul(fk_rotations[i], linalg.VECTOR3F32_Y_AXIS))
  }
  root_position := joints[0]
  target_pos := params.target
  total_length: f32 = 0
  for length in bone_lengths do total_length += length
  aim_bend_at_pole(joints, target_pos, params.pole, clamp(params.pole_weight, 0, 1))
  if linalg.distance(root_position, target_pos) > total_length * 0.999 {
    // unreachable: straighten toward the target
    dir := safe_dir(target_pos - root_position, fk_dirs[0])
    for i in 0 ..< chain_length - 1 do joints[i + 1] = joints[i] + dir * bone_lengths[i]
  } else {
    iterations := params.iterations if params.iterations > 0 else 10
    tolerance := params.tolerance if params.tolerance > 0 else 0.001
    for _ in 0 ..< iterations {
      joints[chain_length - 1] = target_pos
      for i := chain_length - 2; i >= 0; i -= 1 {
        joints[i] = joints[i + 1] - safe_dir(joints[i + 1] - joints[i], fk_dirs[i]) * bone_lengths[i]
      }
      joints[0] = root_position
      for i in 0 ..< chain_length - 1 {
        joints[i + 1] = joints[i] + safe_dir(joints[i + 1] - joints[i], fk_dirs[i]) * bone_lengths[i]
      }
      if linalg.length2(joints[chain_length - 1] - target_pos) < tolerance * tolerance do break
    }
  }
  // write back: each bone swings from its FK segment to its solved one; the last bone, with no
  // segment of its own, swings with its parent
  last_swing := linalg.QUATERNIONF32_IDENTITY
  for i in 0 ..< chain_length - 1 {
    last_swing = linalg.quaternion_between_two_vector3(fk_dirs[i], safe_dir(joints[i + 1] - joints[i], fk_dirs[i]))
    positions[bones[i]] = joints[i]
    rotations[bones[i]] = last_swing * fk_rotations[i]
  }
  positions[bones[chain_length - 1]] = joints[chain_length - 1]
  rotations[bones[chain_length - 1]] = last_swing * fk_rotations[chain_length - 1]
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

// ---------- joint-space solving, over joints' turns within their stops ----------

// A chain being solved in joint space (limited_reach, aim_solve): per bone, its turns from rest
// (JointLimit); `end` is where it reaches with, in its last bone's frame.
@(private = "file")
Ccd :: struct {
  pose:   Pose,
  bones:  []u32,
  angles: [][3]f32,
  stale:  []bool, // per bone, its turns changed since its local rotation was set
  end:    [3]f32,
}

@(private = "file")
ccd_init :: proc(pose: Pose, bones: []u32, end: [3]f32) -> Ccd {
  c := Ccd{pose, bones, make([][3]f32, len(bones), context.temp_allocator), make([]bool, len(bones), context.temp_allocator), end}
  for b, k in bones do c.angles[k] = joint_angles(pose.rest[b].rotation, pose.local[b].rotation)
  return c
}

// Whether the joint of bone b turns about `axis`.
@(private = "file")
turns :: #force_inline proc(pose: Pose, b: u32, axis: int) -> bool {
  l := limit_of(pose, b)
  return l.lo[axis] != l.hi[axis]
}

// Pose the chain's bones from..<to from their turns, each on its parent as posed.
@(private = "file")
ccd_pose :: proc(c: Ccd, from: int, to := max(int)) {
  for k in from ..< min(to, len(c.bones)) {
    b := c.bones[k]
    if c.stale[k] do c.pose.local[b].rotation = c.pose.rest[b].rotation * joint_euler(c.angles[k])
    c.stale[k] = false
    compose_bone(c.pose, b)
    c.pose.rotations[b] = linalg.normalize(c.pose.rotations[b])
  }
}

// Where the chain's end is, as posed.
@(private = "file")
ccd_end :: proc(c: Ccd) -> [3]f32 {
  return bone_point(c.pose, c.bones[len(c.bones) - 1], c.end)
}

// The chain's k-th joint's `axis` in skeleton space, as turned so far (its parent posed as it
// is): from the joint's rest on its parent, x by nothing, y by x, z by x and y.
@(private = "file")
ccd_axis :: proc(c: Ccd, k: int, axis: int) -> [3]f32 {
  b := c.bones[k]
  mo := c.angles[k]
  frame := c.pose.rest[b].rotation
  if p := c.pose.parents[b]; p >= 0 do frame = c.pose.rotations[p] * frame
  if axis >= 1 do frame *= linalg.quaternion_angle_axis_f32(mo.x, {1, 0, 0})
  if axis >= 2 do frame *= linalg.quaternion_angle_axis_f32(mo.y, {0, 1, 0})
  e: [3]f32
  e[axis] = 1
  return linalg.normalize(linalg.mul(frame, e))
}

// Turn the chain's k-th joint (posed on its parent as it is) about its `axis` as far as it takes
// point `at` toward `want`, within its limit.
@(private = "file")
ccd_turn :: proc(c: Ccd, k: int, axis: int, at, want: [3]f32) {
  b := c.bones[k]
  pivot := c.pose.positions[b]
  n := ccd_axis(c, k, axis)
  u, v := at - pivot, want - pivot
  lu, lv := linalg.length2(u), linalg.length2(v)
  u -= linalg.dot(u, n) * n
  v -= linalg.dot(v, n) * n
  // a point (nearly) on the axis isn't turned by it: its turn would be noise, flipping the
  // joint between its stops
  if linalg.length2(u) < max(1e-10, 1e-4 * lu) || linalg.length2(v) < max(1e-10, 1e-4 * lv) do return
  c.angles[k][axis] += math.atan2(linalg.dot(n, linalg.cross(u, v)), linalg.dot(u, v))
  c.angles[k] = joint_clamp(c.angles[k], limit_of(c.pose, b))
  c.stale[k] = true
}

// Where the middle joint (chain index `mid`) must be for the end to reach `target`, its two
// segments (the joint above it to it, it to the end) as long as they are: off the line from the
// joint above it to the target, toward `pole`, and never less than a hundredth of its segment off
// it (straight, or out of reach, it still bends the pole's way). ok is false when the pole is on
// that line.
@(private = "file")
ccd_middle :: proc(c: Ccd, mid: int, target, pole: [3]f32) -> (want: [3]f32, ok: bool) {
  r := c.pose.positions[c.bones[mid - 1]]
  at := c.pose.positions[c.bones[mid]]
  la, lb := linalg.length(at - r), linalg.length(ccd_end(c) - at)
  d := linalg.length(target - r)
  if d < 1e-5 do return
  line := (target - r) / d
  toward := (pole - r) - linalg.dot(pole - r, line) * line
  if linalg.length2(toward) < 1e-10 do return
  // never quite on the line, so the pole's side still says which way it bends
  h := 0.01 * la
  if d < la + lb {
    x := clamp((la * la - lb * lb + d * d) / (2 * d), -la, la)
    h = max(h, math.sqrt(max(0, la * la - x * x)))
  }
  return r + line * math.sqrt(max(0, la * la - h * h)) + linalg.normalize(toward) * h, true
}

// Reach a limited chain by damped least squares over its joints' turns, from the pose it has: its
// end onto the target, its middle joint toward where the pole puts it and, with `hold`, its end
// facing as it did, weighed together; then a few steps with the facing let go settle the first two
// exactly (they always agree, so the facing gives up only what they need). Each step moves the
// joints the least that does it, within their stops (a joint on a stop the step pushes further onto
// sits that step out). The end's own joints reach too when they hold, and keep their turns otherwise.
@(private = "file")
limited_reach :: proc(pose: Pose, bones: []u32, params: IKParams) {
  c := ccd_init(pose, bones, params.end)
  n := len(bones)
  reaching := n - min(int(params.ends), n - 1)
  moving := n if params.hold else reaching
  mid := int(params.middle) if params.pole_weight > 0 && int(params.middle) < reaching else 0
  iterations := params.iterations if params.iterations > 0 else 10
  tolerance := params.tolerance if params.tolerance > 0 else 0.001
  last := bones[n - 1]
  keep := pose.rotations[last]
  // the joints' turns being solved
  Dof :: struct {
    k, axis: int,
  }
  dofs := make([dynamic]Dof, 0, 3 * moving, context.temp_allocator)
  for k in 0 ..< moving do for axis in 0 ..< 3 do if turns(pose, bones[k], axis) do append(&dofs, Dof{k, axis})
  m := len(dofs)
  if m == 0 do return
  length: f32 = 0
  for k in 1 ..< n do length += linalg.distance(pose.positions[bones[k]], pose.positions[bones[k - 1]])
  length = max(length + linalg.distance(ccd_end(c), pose.positions[last]), 1e-3)
  damping := 0.05 * length
  // rows: the end's place, the middle's place, the end's facing (as an arc at the chain's length)
  ROWS :: 9
  WEIGHT :: [ROWS]f32{2, 2, 2, 4, 4, 4, 1, 1, 1}
  jac := make([][ROWS]f32, m, context.temp_allocator)
  a := make([]f32, m * m, context.temp_allocator)
  step := make([]f32, m, context.temp_allocator)
  active := make([]bool, m, context.temp_allocator)
  SETTLE :: 6
  for it in 0 ..< iterations + SETTLE {
    facing := params.hold && it < iterations
    ccd_pose(c, 0)
    end := ccd_end(c)
    err: [ROWS]f32
    err[0], err[1], err[2] = expand_values(params.target - end)
    at: [3]f32
    if mid > 0 {
      at = pose.positions[bones[mid]]
      if want, ok := ccd_middle(c, mid, params.target, params.pole); ok do err[3], err[4], err[5] = expand_values(want - at)
    }
    if facing {
      // the turn from how it faces to how it faced, as a rotation vector
      q := keep * linalg.quaternion_inverse(pose.rotations[last])
      if q.w < 0 do q = -q
      v := [3]f32{q.x, q.y, q.z}
      if s := linalg.length(v); s > 1e-9 do v *= 2 * math.atan2(s, q.w) / s
      err[6], err[7], err[8] = expand_values(v * length)
    }
    // all met: nothing to settle either
    if linalg.length([3]f32{err[0], err[1], err[2]}) < tolerance && linalg.length([3]f32{err[3], err[4], err[5]}) < tolerance && linalg.length([3]f32{err[6], err[7], err[8]}) < tolerance do break
    weight := WEIGHT
    for d, j in dofs {
      axis := ccd_axis(c, d.k, d.axis)
      pivot := pose.positions[bones[d.k]]
      col: [ROWS]f32
      col[0], col[1], col[2] = expand_values(linalg.cross(axis, end - pivot))
      if d.k < mid do col[3], col[4], col[5] = expand_values(linalg.cross(axis, at - pivot))
      if facing do col[6], col[7], col[8] = expand_values(axis * length)
      jac[j] = col
    }
    // a joint on a stop the step pushes further onto sits it out
    for d, j in dofs {
      g: f32 = 0
      for r in 0 ..< ROWS do g += jac[j][r] * weight[r] * weight[r] * err[r]
      step[j] = g
      l := limit_of(pose, bones[d.k])
      v := c.angles[d.k][d.axis]
      // and with the facing let go, the end's own joints keep how they face
      active[j] = !(v >= l.hi[d.axis] && g > 0) && !(v <= l.lo[d.axis] && g < 0) && (facing || d.k < reaching)
      if !active[j] do step[j] = 0
    }
    // (JᵀW²J + λ²I) step = JᵀW²e over the active turns
    for i in 0 ..< m do for j in 0 ..< m {
      sum: f32 = damping * damping if i == j else 0
      if active[i] && active[j] do for r in 0 ..< ROWS do sum += jac[i][r] * weight[r] * weight[r] * jac[j][r]
      a[i * m + j] = sum
    }
    if !cholesky_factor(a, m) do break
    cholesky_solve(a, step, m)
    moved: f32 = 0
    for d, j in dofs {
      if !active[j] do continue
      t := clamp(step[j], -0.5, 0.5)
      c.angles[d.k][d.axis] += t
      c.angles[d.k] = joint_clamp(c.angles[d.k], limit_of(pose, bones[d.k]))
      c.stale[d.k] = true
      moved = max(moved, abs(t))
    }
    if moved < 1e-5 && !facing do break
  }
  ccd_pose(c, 0)
}

// cholesky_factor factors the symmetric positive-definite n x n matrix a (row-major) in place
// into its lower triangle L (a = L Lᵀ); false when a is not positive definite.
@(private = "file")
cholesky_factor :: proc(a: []f32, n: int) -> bool {
  for j in 0 ..< n {
    d := a[j * n + j]
    for k in 0 ..< j do d -= a[j * n + k] * a[j * n + k]
    if d <= 1e-12 do return false
    d = math.sqrt(d)
    a[j * n + j] = d
    for i in j + 1 ..< n {
      s := a[i * n + j]
      for k in 0 ..< j do s -= a[i * n + k] * a[j * n + k]
      a[i * n + j] = s / d
    }
  }
  return true
}

// cholesky_solve solves L Lᵀ x = b in place (b becomes x), a factored by cholesky_factor.
@(private = "file")
cholesky_solve :: proc(a, b: []f32, n: int) {
  for i in 0 ..< n {
    s := b[i]
    for k in 0 ..< i do s -= a[i * n + k] * b[k]
    b[i] = s / a[i * n + i]
  }
  for i := n - 1; i >= 0; i -= 1 {
    s := b[i]
    for k in i + 1 ..< n do s -= a[k * n + i] * b[k]
    b[i] = s / a[i * n + i]
  }
}

// aim_solve turns the chain `bones` (root first, each the parent of the next), end first, so
// the last bone's `look` (a direction in its frame) points from its point `eye` (in its frame)
// at `target` (skeleton space): each joint about the axes it turns within its limit, the end's
// own joints (a neck) doing the most. Needs the pose's local and rest transforms and scales.
aim_solve :: proc(pose: Pose, bones: []u32, look, eye, target: [3]f32, iterations := 8) {
  if len(bones) == 0 do return
  for idx in bones do if int(idx) >= len(pose.positions) do return
  c := ccd_init(pose, bones, eye)
  last := bones[len(bones) - 1]
  for _ in 0 ..< iterations {
    for k := len(bones) - 1; k >= 0; k -= 1 {
      for axis in 0 ..< 3 {
        if !turns(pose, bones[k], axis) do continue
        ccd_pose(c, k)
        pivot := pose.positions[bones[k]]
        // turn the way the end looks toward the way to the target, about this joint
        ccd_turn(c, k, axis, pivot + linalg.mul(pose.rotations[last], look), pivot + linalg.normalize0(target - ccd_end(c)))
      }
    }
  }
  ccd_pose(c, 0)
}

// ik_chain_middle is the index in chain `bones` of the joint that bends it nearest halfway along
// it, from its root's pivot through each pivot to its end (`end` in the last bone's frame), over
// its first `reaching` bones (0: all), as posed: the knee of a leg, the elbow of an arm. A joint
// bends the chain when it turns about an axis across the line from it to the end (a twist along
// the limb doesn't); 0 when none does. Run it once, on the rest pose, for IKParams.middle.
ik_chain_middle :: proc(pose: Pose, bones: []u32, end: [3]f32, reaching := 0) -> u32 {
  if len(bones) < 2 do return 0
  chain := bones[:reaching if reaching > 0 else len(bones)]
  last := bones[len(bones) - 1]
  tip := bone_point(pose, last, end)
  along := make([]f32, len(chain) + 1, context.temp_allocator)
  for k in 1 ..< len(chain) do along[k] = along[k - 1] + linalg.length(pose.positions[chain[k]] - pose.positions[chain[k - 1]])
  along[len(chain)] = along[len(chain) - 1] + linalg.length(tip - pose.positions[chain[len(chain) - 1]])
  half := along[len(chain)] / 2
  best := 0
  for k in 1 ..< len(chain) {
    to := linalg.normalize0(tip - pose.positions[chain[k]])
    bends := false
    for axis in 0 ..< 3 {
      if !turns(pose, chain[k], axis) do continue
      e: [3]f32
      e[axis] = 1
      bends ||= abs(linalg.dot(linalg.mul(pose.rotations[chain[k]], e), to)) < 0.7
    }
    if bends && (best == 0 || abs(along[k] - half) < abs(along[best] - half)) do best = k
  }
  return u32(best)
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

