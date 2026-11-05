#+build !js
#+private
package animation

import "../geometry"
import "core:math/linalg"
import "core:testing"

// A human-like leg standing on the ground, its hip `lift` up: hip, knee, ankle (the foot's own
// joint), toes below the foot; every joint a pin about x, the knee a little bent at rest (a stance),
// the foot level. The sole is 0.1 below the ankle; the foot runs
// from its heel (0.1 back) to its ball (0.15 ahead), the toes 0.1 on.
@(private = "file")
Rigged :: struct {
  ground:   f32, // where the ground is: under the sole at rest
  rest:     [3]f32, // where the sole is at rest
  pose:     Pose,
  chain:    []u32,
  leg:      LegRig,
  foot:     FootRig,
  corners:  [dynamic][3]f32,
  conforms: [dynamic]FootConform,
}

@(private = "file")
rigged :: proc(lift: f32 = 0) -> (r: Rigged) {
  n :: 4
  offsets := [n][3]f32{{0, 2 + lift, 0}, {0, -1, 0}, {0, -0.9, 0}, {0, -0.05, 0.15}}
  limits := [n]JointLimit{{{-1.5, 0, 0}, {1.5, 0, 0}}, {{-0.6, 0, 0}, {1.9, 0, 0}}, {{-1.2, 0, 0}, {1.2, 0, 0}}, {{-0.8, 0, 0}, {0.8, 0, 0}}}
  r.pose = Pose {
    local      = make([]geometry.Transform, n, context.temp_allocator),
    positions  = make([][3]f32, n, context.temp_allocator),
    rotations  = make([]quaternion128, n, context.temp_allocator),
    scales     = make([][3]f32, n, context.temp_allocator),
    parents    = make([]i32, n, context.temp_allocator),
    order      = make([]u32, n, context.temp_allocator),
    lengths    = make([]f32, n, context.temp_allocator),
    rest       = make([]geometry.Transform, n, context.temp_allocator),
    limits     = make([]JointLimit, n, context.temp_allocator),
    root_world = linalg.MATRIX4F32_IDENTITY,
    root_inv   = linalg.MATRIX4F32_IDENTITY,
  }
  for i in 0 ..< n {
    r.pose.parents[i], r.pose.order[i] = i32(i) - 1, u32(i)
    bent := [n]f32{-0.3, 0.6, -0.3, 0}
    r.pose.local[i] = {offsets[i], linalg.quaternion_angle_axis_f32(bent[i], {1, 0, 0}), 1}
    r.pose.rest[i] = r.pose.local[i]
    r.pose.lengths[i] = linalg.length(offsets[i]) if i > 0 else 0
    r.pose.limits[i] = limits[i]
  }
  pose_compose(r.pose)
  r.chain = make([]u32, 3, context.temp_allocator)
  r.chain[0], r.chain[1], r.chain[2] = 0, 1, 2
  r.leg = leg_measure(r.pose, r.chain, {0, -0.1, 0}, ends = 1)
  r.rest = bone_point(r.pose, 2, {0, -0.1, 0})
  r.ground = r.rest.y
  corners := make([dynamic]BoneCorner, context.temp_allocator)
  for x in ([]f32{-0.05, 0.05}) {
    for z in ([]f32{-0.1, 0.15}) do append(&corners, BoneCorner{2, {x, -0.1, z}}, BoneCorner{2, {x, 0, z}})
    for z in ([]f32{0, 0.1}) do append(&corners, BoneCorner{3, {x, -0.05, z}}, BoneCorner{3, {x, 0, z}})
  }
  r.corners = make([dynamic][3]f32, context.temp_allocator)
  r.conforms = make([dynamic]FootConform, context.temp_allocator)
  r.foot = foot_measure(r.pose, r.chain, r.leg, corners[:], &r.corners, &r.conforms, r.ground)
  return
}

// Where the foot stands for a target `offset` from where it stood at rest: its heel's and its ball's lowest, and the lowest of the foot and its
// toes, over the ground.
@(private = "file")
stance :: proc(r: Rigged, offset: [3]f32) -> (heel, ball, low: f32) {
  ground := r.ground
  toes := foot_solve(r.pose, r.chain, r.leg, r.foot, r.corners[:], r.conforms[:], r.rest + offset, 0, 0, ground = ground)
  moved := make([]bool, 4, context.temp_allocator)
  moved[2] = true
  pose_propagate(r.pose, moved)
  foot_conform(r.pose, r.foot, r.corners[:], r.conforms[:], toes, ground)
  heel, ball, low = max(f32), max(f32), max(f32)
  for c in r.corners[r.foot.corners_first:][:r.foot.corners_count] {
    y := bone_point(r.pose, 2, c).y - ground
    if c.z < 0 do heel = min(heel, y)
    else do ball = min(ball, y)
    low = min(low, y)
  }
  for cf in r.conforms do for c in r.corners[cf.first:][:cf.count] do low = min(low, bone_point(r.pose, cf.bone, c).y - ground)
  return
}

// Each solved from rest: a foot stands flat where it stood, lands on its heel ahead, peels its heel up as the leg runs out
// of reach behind, never goes through the ground, and does all that on ground at any height.
@(test)
test_foot_contact :: proc(t: ^testing.T) {
  r := rigged()
  testing.expectf(t, r.foot.corners_count == 8 && r.foot.conform_count == 1 && r.foot.span > 0, "measured: %v", r.foot)
  heel, ball, low := stance(r, {0, 0, 0})
  testing.expectf(t, abs(heel) < 1e-3 && abs(ball) < 1e-3, "flat where it stood: heel %v, ball %v", heel, ball)
  heel, ball, _ = stance(rigged(), {0, 0.03, 0.4})
  testing.expectf(t, heel < ball - 0.02, "reaching ahead it lands on its heel: heel %v, ball %v", heel, ball)
  heel, ball, _ = stance(rigged(), {0, 0, -0.6})
  testing.expectf(t, heel > ball + 0.02 && ball < 0.01, "far behind its heel peels up, the ball down: heel %v, ball %v", heel, ball)
  for z := f32(-0.7); z <= 0.6; z += 0.1 do for y in ([]f32{0, 0.05, 0.2}) {
    _, _, low = stance(rigged(), {0, y, z})
    testing.expectf(t, low > -0.01, "at %v, %v nothing goes through the ground: %v", y, z, low)
  }
  // the same leg on ground half a unit up stands the same, half a unit up
  for target in ([][3]f32{{0, 0, 0}, {0, 0.03, 0.4}, {0, 0, -0.4}}) {
    r0, r1 := rigged(), rigged(0.5)
    stance(r0, target)
    stance(r1, target)
    for b in 0 ..< 4 do testing.expectf(t, linalg.length(r1.pose.positions[b] - (r0.pose.positions[b] + {0, 0.5, 0})) < 1e-3, "on raised ground at %v, bone %d where it was, raised", target, b)
  }
}
