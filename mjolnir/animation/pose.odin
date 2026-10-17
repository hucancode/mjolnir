package animation

import "../geometry"
import "core:math/linalg"
import "core:slice"

// Pose is an Animator's pose during animator_update, as procedural layers see it: per bone,
// the local transform (from the clip layers) and the skeleton-space transform, plus the
// skeleton and the animator's joint limits. root_world places skeleton space in the world.
// A view: valid inside a CustomApply call only.
Pose :: struct {
  local:      []TRS,
  positions:  [][3]f32,
  rotations:  []quaternion128,
  scales:     [][3]f32,
  parents:    []i32, // -1 = root
  order:      []u32, // parents before children
  lengths:    []f32, // rest distance to parent
  limits:     []JointLimit,
  root_world: matrix[4, 4]f32,
  root_inv:   matrix[4, 4]f32,
}

// JointLimit bounds how far IK turns a bone from its incoming pose: max_angle is
// (swing X, twist Y, swing Z) in radians about bone-local axes (Y is forward). Negative =
// unconstrained, zero = locked.
JointLimit :: struct {
  max_angle: [3]f32,
}

// JOINT_FREE is the limit of a bone IK may turn freely, every bone's default.
JOINT_FREE :: JointLimit{{-1, -1, -1}}

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
  pose.rotations[bone] = linalg.quaternion_between_two_vector3(geometry.qy(rot), linalg.normalize(direction)) * rot
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
  pose.positions[i] = pose.positions[parent] + geometry.qmv(pr, ps * l.position)
  pose.rotations[i] = pr * l.rotation
  pose.scales[i] = ps * l.scale
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
// (`positions`, `rotations`, one per bone in `bones`) to their current ones by `weight`:
// rotations slerp; a bone whose parent is also in `bones` keeps hanging off it, with its
// length blended; the others lerp.
pose_blend :: proc(pose: Pose, bones: []u32, positions: [][3]f32, rotations: []quaternion128, weight: f32) {
  if weight >= 1 do return
  if weight <= 0 {
    for b, k in bones do pose.positions[b], pose.rotations[b] = positions[k], rotations[k]
    return
  }
  // slot of each bone in `bones`, -1 when absent
  slot := make([]i32, len(pose.parents), context.temp_allocator)
  slice.fill(slot, -1)
  for b, k in bones do slot[b] = i32(k)
  solved := make([][3]f32, len(bones), context.temp_allocator)
  for b, k in bones do solved[k] = pose.positions[b]
  for b in pose.order {
    k := slot[b]
    if k < 0 do continue
    pose.rotations[b] = linalg.quaternion_slerp(rotations[k], pose.rotations[b], weight)
    p := pose.parents[b]
    if p < 0 || slot[p] < 0 {
      pose.positions[b] = linalg.lerp(positions[k], solved[k], weight)
      continue
    }
    kp := slot[p]
    before := positions[k] - positions[kp]
    after := solved[k] - solved[kp]
    // the bone keeps its place on the parent as the parent turns from before to blended
    turned := geometry.qmv(pose.rotations[p] * linalg.quaternion_inverse(rotations[kp]), before)
    length := linalg.lerp(linalg.length(before), linalg.length(after), weight)
    if l := linalg.length(turned); l > 1e-6 do turned *= length / l
    pose.positions[b] = pose.positions[p] + turned
  }
}
