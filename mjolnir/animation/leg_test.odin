#+build !js
#+private
package animation

import "../geometry"
import "core:math/linalg"
import "core:testing"

// A three-bone leg (hip, knee, foot) from `points`, at rest as given, each joint turning about x
// within `limits` (nil: free).
@(private = "file")
test_leg :: proc(points: [3][3]f32, limits: []JointLimit = nil) -> (pose: Pose, chain: []u32) {
  n :: 3
  pose = Pose {
    local      = make([]geometry.Transform, n, context.temp_allocator),
    positions  = make([][3]f32, n, context.temp_allocator),
    rotations  = make([]quaternion128, n, context.temp_allocator),
    scales     = make([][3]f32, n, context.temp_allocator),
    parents    = make([]i32, n, context.temp_allocator),
    order      = make([]u32, n, context.temp_allocator),
    lengths    = make([]f32, n, context.temp_allocator),
    rest       = make([]geometry.Transform, n, context.temp_allocator),
    limits     = limits,
    root_world = linalg.MATRIX4F32_IDENTITY,
    root_inv   = linalg.MATRIX4F32_IDENTITY,
  }
  chain = make([]u32, n, context.temp_allocator)
  for i in 0 ..< n {
    pose.parents[i], pose.order[i], chain[i] = i32(i) - 1, u32(i), u32(i)
    at := points[i] - (points[i - 1] if i > 0 else 0)
    pose.local[i] = {at, linalg.QUATERNIONF32_IDENTITY, 1}
    pose.rest[i] = pose.local[i]
    pose.lengths[i] = linalg.length(at) if i > 0 else 0
  }
  pose_compose(pose)
  return
}

// A pin about x within lo, hi.
@(private = "file")
pin :: proc(lo, hi: f32) -> JointLimit {
  return {{lo, 0, 0}, {hi, 0, 0}}
}

// Every kind of leg bends the way it is built, with no pole given: a human knee forward and a dog's
// hock back (both straight at rest: the way their stops let them), a spider's knee up (bent so at
// rest); and leg_pole's swivel swings the knee out.
@(test)
test_leg_bends_as_built :: proc(t: ^testing.T) {
  straight := [3][3]f32{{0, 0, 0}, {0, -1, 0}, {0, -2, 0}}
  squat := [3]f32{0, -1.5, 0}
  {
    // a human knee: its shin turns +x, swinging the foot back (-z), the knee forward
    pose, chain := test_leg(straight, []JointLimit{pin(-1.5, 1.5), pin(0, 2.5), {}})
    leg := leg_measure(pose, chain, {})
    testing.expectf(t, leg.middle == 1 && linalg.dot(leg.bend, {0, 0, 1}) > 0.99, "a knee bends forward: %v", leg)
    leg_reach(pose, chain, leg, squat)
    testing.expectf(t, pose.positions[1].z > 0.3, "the knee forward: %v", pose.positions[1])
    testing.expectf(t, linalg.length(pose.positions[2] - squat) < 1e-2, "the foot on its target: %v", pose.positions[2])
  }
  {
    // a dog's hock: the other way round
    pose, chain := test_leg(straight, []JointLimit{pin(-1.5, 1.5), pin(-2.5, 0), {}})
    leg := leg_measure(pose, chain, {})
    leg_reach(pose, chain, leg, squat)
    testing.expectf(t, pose.positions[1].z < -0.3, "the hock back: %v", pose.positions[1])
    testing.expectf(t, linalg.length(pose.positions[2] - squat) < 1e-2, "the foot on its target: %v", pose.positions[2])
  }
  {
    // a spider's leg: bent knee-up at rest, its joints free
    pose, chain := test_leg({{0, 0, 0}, {1, 1, 0}, {2, 0, 0}})
    leg := leg_measure(pose, chain, {})
    testing.expectf(t, linalg.dot(leg.bend, {0, 1, 0}) > 0.99, "bent up at rest: %v", leg)
    target := [3]f32{1.5, -0.3, 0.2}
    leg_reach(pose, chain, leg, target)
    testing.expectf(t, pose.positions[1].y > 0.3, "the knee up: %v", pose.positions[1])
    testing.expectf(t, linalg.length(pose.positions[2] - target) < 1e-2, "the foot on its target: %v", pose.positions[2])
    // swivel a quarter turn about hip to foot: the knee swung out to the side
    out := leg_pole(leg, pose, chain, target, 1.5707964)
    testing.expectf(t, abs(out.z - (0 + target.z) / 2) > 0.5 * leg.length, "the swivel swings the pole out: %v", out)
  }
}
