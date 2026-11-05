package animation

import "../geometry"
import "core:math"
import "core:math/linalg"
import "core:slice"

// Pose is a skeleton's pose as procedural code edits it: per bone, the local transform (from the
// clip layers) and the skeleton-space transform, plus the skeleton (its rest pose included) and
// the joint limits.
// root_world places skeleton space in the world. An Animator hands its own to each CustomApply
// (a view valid for that call); fill one over arrays of your own to run ik_solve, aim_bone or
// pose_blend on a pose you hold.
Pose :: struct {
  local:      []geometry.Transform,
  positions:  [][3]f32,
  rotations:  []quaternion128,
  scales:     [][3]f32,
  parents:    []i32, // -1 = root
  order:      []u32, // parents before children
  lengths:    []f32, // rest distance to parent
  rest:       []geometry.Transform, // local rest pose (Skeleton.rest)
  limits:     []JointLimit,
  root_world: matrix[4, 4]f32,
  root_inv:   matrix[4, 4]f32,
}

// JointLimit is a joint's stops: how far each bone may turn from its local rest rotation about
// its own x, y, z axes (Y is along the bone), in radians, the turns composed as
// rest * Rx(x) * Ry(y) * Rz(z) (joint_rotation). lo == hi on an axis locks it: a hinge is free on
// one axis and locked on the other two. IK keeps every bone within its stops; a chain with none
// solves faster (ik_solve).
JointLimit :: struct {
  lo, hi: [3]f32,
}

// JOINT_FREE is the limit of a bone free to turn any way, every bone's default.
JOINT_FREE :: JointLimit{-math.F32_MAX, math.F32_MAX}

// joint_euler is the rotation of turns `angles` about x, then y, then z, each about the already
// turned axes (Rx * Ry * Rz).
joint_euler :: proc(angles: [3]f32) -> quaternion128 {
  qx := linalg.quaternion_angle_axis_f32(angles.x, {1, 0, 0})
  qy := linalg.quaternion_angle_axis_f32(angles.y, {0, 1, 0})
  qz := linalg.quaternion_angle_axis_f32(angles.z, {0, 0, 1})
  return linalg.normalize(qx * qy * qz)
}

// joint_clamp holds turns `angles` within `limit`.
joint_clamp :: #force_inline proc(angles: [3]f32, limit: JointLimit) -> [3]f32 {
  return linalg.clamp(angles, limit.lo, limit.hi)
}

// joint_rotation is a bone's local rotation turned `angles` from its rest rotation, within its
// limit.
joint_rotation :: proc(rest: quaternion128, angles: [3]f32, limit: JointLimit) -> quaternion128 {
  return linalg.normalize(rest * joint_euler(joint_clamp(angles, limit)))
}

// joint_angles is how far local rotation `local` is turned from rest rotation `rest`, as turns
// about x, y, z (joint_rotation's inverse; y within ±pi/2).
joint_angles :: proc(rest, local: quaternion128) -> [3]f32 {
  q := linalg.quaternion_inverse(rest) * local
  x, y, z, w := q.x, q.y, q.z, q.w
  m02 := clamp(2 * (x * z + w * y), -1, 1)
  if abs(m02) > 0.99999 {
    // gimbal lock: x and z turn about the same axis, put it all on x
    return {math.atan2(2 * (y * z + w * x), 1 - 2 * (x * x + z * z)), math.asin(m02), 0}
  }
  return {math.atan2(-2 * (y * z - w * x), 1 - 2 * (x * x + y * y)), math.asin(m02), math.atan2(-2 * (x * y - w * z), 1 - 2 * (y * y + z * z))}
}

// The limit of bone b; JOINT_FREE for a pose without limits.
@(private)
limit_of :: #force_inline proc(pose: Pose, b: u32) -> JointLimit {
  return pose.limits[b] if int(b) < len(pose.limits) else JOINT_FREE
}

// limited reports whether `bones` has a bone that is not JOINT_FREE.
@(private)
limited :: proc(pose: Pose, bones: []u32) -> bool {
  for b in bones do if limit_of(pose, b) != JOINT_FREE do return true
  return false
}

// bone_point is point `p`, in bone b's frame, in skeleton space.
@(private)
bone_point :: #force_inline proc(pose: Pose, b: u32, p: [3]f32) -> [3]f32 {
  return pose.positions[b] + linalg.mul(pose.rotations[b], pose.scales[b] * p)
}

// to_world returns a skeleton-space point in world space.
to_world :: #force_inline proc(pose: Pose, p: [3]f32) -> [3]f32 {
  return (pose.root_world * [4]f32{p.x, p.y, p.z, 1}).xyz
}

// to_model returns a world-space point in skeleton space.
to_model :: #force_inline proc(pose: Pose, p: [3]f32) -> [3]f32 {
  return (pose.root_inv * [4]f32{p.x, p.y, p.z, 1}).xyz
}

// aim_bone turns `bone` so its Y axis points along `direction` (skeleton space).
aim_bone :: proc(pose: Pose, bone: u32, direction: [3]f32) {
  if linalg.length2(direction) < 1e-6 do return
  rot := pose.rotations[bone]
  pose.rotations[bone] = linalg.quaternion_between_two_vector3(linalg.mul(rot, linalg.VECTOR3F32_Y_AXIS), linalg.normalize(direction)) * rot
}

// Skeleton-space transform of bone `i` from its local transform and its
// parent's skeleton-space transform (scale does not shear).
@(private)
compose_bone :: #force_inline proc(pose: Pose, i: u32) {
  l := pose.local[i]
  parent := pose.parents[i]
  if parent < 0 {
    pose.positions[i], pose.rotations[i], pose.scales[i] = l.position, l.rotation, l.scale
    return
  }
  pr := pose.rotations[parent]
  ps := pose.scales[parent]
  pose.positions[i] = pose.positions[parent] + linalg.mul(pr, ps * l.position)
  pose.rotations[i] = pr * l.rotation
  pose.scales[i] = ps * l.scale
}

// pose_compose sets every bone's skeleton-space transform from its local transform.
pose_compose :: proc(pose: Pose) {
  for i in pose.order do compose_bone(pose, i)
}

// pose_at_rest is `pose`'s skeleton at rest (its local rest transforms, composed), in arrays of
// its own (temp-allocated), to read how it is built; a pose without rest transforms, as posed.
pose_at_rest :: proc(pose: Pose) -> Pose {
  n := len(pose.parents)
  out := pose
  out.local = make([]geometry.Transform, n, context.temp_allocator)
  out.positions = make([][3]f32, n, context.temp_allocator)
  out.rotations = make([]quaternion128, n, context.temp_allocator)
  out.scales = make([][3]f32, n, context.temp_allocator)
  if len(pose.rest) == n {
    copy(out.local, pose.rest)
    pose_compose(out)
    return out
  }
  copy(out.local, pose.local)
  copy(out.positions, pose.positions)
  copy(out.rotations, pose.rotations)
  copy(out.scales, pose.scales)
  return out
}

// pose_propagate moves the descendants of the `moved` bones (indexed by bone) that are not
// moved themselves, keeping their local transforms.
pose_propagate :: proc(pose: Pose, moved: []bool) {
  dirty := make([]bool, len(moved), context.temp_allocator)
  for i in pose.order {
    p := pose.parents[i]
    if p < 0 || moved[i] || !(moved[p] || dirty[p]) do continue
    compose_bone(pose, i)
    dirty[i] = true
  }
}

// pose_blend blends `bones` from their skeleton-space transforms before an edit
// (`positions`, `rotations`, one per bone in `bones`) to their current ones by `weight`: a bone
// with a limit blends its joint's turns (joint_angles), so it stays on its axes and within its
// stops; otherwise rotations slerp, a bone whose parent is also in `bones` keeps hanging off it,
// with its length blended, and the others lerp.
pose_blend :: proc(pose: Pose, bones: []u32, positions: [][3]f32, rotations: []quaternion128, weight: f32) {
  if weight >= 1 do return
  has_limits := limited(pose, bones)
  if weight <= 0 && !has_limits {
    for b, k in bones do pose.positions[b], pose.rotations[b] = positions[k], rotations[k]
    return
  }
  // slot of each bone in `bones`, -1 when absent
  slot := make([]i32, len(pose.parents), context.temp_allocator)
  slice.fill(slot, -1)
  for b, k in bones do slot[b] = i32(k)
  solved := make([][3]f32, len(bones), context.temp_allocator)
  for b, k in bones do solved[k] = pose.positions[b]
  solved_rotations: []quaternion128
  if has_limits {
    solved_rotations = make([]quaternion128, len(bones), context.temp_allocator)
    for b, k in bones do solved_rotations[k] = pose.rotations[b]
  }
  for b in pose.order {
    k := slot[b]
    if k < 0 do continue
    p := pose.parents[b]
    kp := slot[p] if p >= 0 else -1
    if has_limits && limit_of(pose, b) != JOINT_FREE {
      // the joint's turns before and after, each from its parent as it was then
      parent_before, parent_after := linalg.QUATERNIONF32_IDENTITY, linalg.QUATERNIONF32_IDENTITY
      if p >= 0 do parent_before, parent_after = pose.rotations[p], pose.rotations[p]
      if kp >= 0 do parent_before, parent_after = rotations[kp], solved_rotations[kp]
      rest := pose.rest[b].rotation
      from := joint_angles(rest, linalg.quaternion_inverse(parent_before) * rotations[k])
      to := joint_angles(rest, linalg.quaternion_inverse(parent_after) * solved_rotations[k])
      pose.local[b].rotation = linalg.normalize(rest * joint_euler(linalg.lerp(from, to, weight)))
      compose_bone(pose, b)
      continue
    }
    pose.rotations[b] = linalg.quaternion_slerp(rotations[k], pose.rotations[b], weight)
    if kp < 0 {
      pose.positions[b] = linalg.lerp(positions[k], solved[k], weight)
      continue
    }
    before := positions[k] - positions[kp]
    after := solved[k] - solved[kp]
    // the bone keeps its place on the parent as the parent turns from before to blended
    turned := linalg.mul(pose.rotations[p] * linalg.quaternion_inverse(rotations[kp]), before)
    length := linalg.lerp(linalg.length(before), linalg.length(after), weight)
    if l := linalg.length(turned); l > 1e-6 do turned *= length / l
    pose.positions[b] = pose.positions[p] + turned
  }
}
