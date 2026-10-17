#+build !js
#+private
package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

// A pose over `n` bones in a chain (each the parent of the next) along `dir`, 1 apart, with
// identity rotations, temp-allocated.
test_chain_pose :: proc(n: int, dir: [3]f32 = {0, 1, 0}) -> Pose {
  pose := Pose {
    local      = make([]TRS, n, context.temp_allocator),
    positions  = make([][3]f32, n, context.temp_allocator),
    rotations  = make([]quaternion128, n, context.temp_allocator),
    scales     = make([][3]f32, n, context.temp_allocator),
    parents    = make([]i32, n, context.temp_allocator),
    order      = make([]u32, n, context.temp_allocator),
    lengths    = make([]f32, n, context.temp_allocator),
    root_world = linalg.MATRIX4F32_IDENTITY,
    root_inv   = linalg.MATRIX4F32_IDENTITY,
  }
  for i in 0 ..< n {
    pose.positions[i] = dir * f32(i)
    pose.rotations[i] = linalg.QUATERNIONF32_IDENTITY
    pose.scales[i] = 1
    pose.parents[i] = i32(i) - 1
    pose.order[i] = u32(i)
    pose.lengths[i] = 1 if i > 0 else 0
    pose.local[i] = {position = dir if i > 0 else 0, rotation = linalg.QUATERNIONF32_IDENTITY, scale = 1}
  }
  return pose
}

// tail -----------------------------------------------------------

@(test)
test_tail_fresh_starts_at_pose :: proc(t: ^testing.T) {
  pose := test_chain_pose(4)
  state := make([]f32, TAIL_STATE * 4, context.temp_allocator)
  tail_apply(pose, {0, 1, 2, 3}, state, {stiffness = 0.5, damping = 1}, 1.0 / 60.0, fresh = true)
  // a resting chain starts settled: each bone where its parent's tip is
  for i in 0 ..< 4 do testing.expectf(t, linalg.distance(pose.positions[i], [3]f32{0, f32(i), 0}) < 1e-4, "bone %d at %v", i, pose.positions[i])
}

@(test)
test_tail_short_chain_no_op :: proc(t: ^testing.T) {
  pose := test_chain_pose(1)
  state := make([]f32, TAIL_STATE, context.temp_allocator)
  tail_apply(pose, {0}, state, {stiffness = 0.5, damping = 1}, 0.016, fresh = true)
  testing.expect(t, pose.positions[0] == {0, 0, 0}, "single-bone chain skipped")
}

@(test)
test_tail_lags_then_settles :: proc(t: ^testing.T) {
  state := make([]f32, TAIL_STATE * 3, context.temp_allocator)
  pose := test_chain_pose(3)
  tail_apply(pose, {0, 1, 2}, state, {stiffness = 1, damping = 1}, 1.0 / 60.0, fresh = true)
  // the rig jumps: the tail lags in world space, so in skeleton space it trails behind
  moved := test_chain_pose(3)
  moved.root_world = linalg.matrix4_translate_f32({1, 0, 0})
  moved.root_inv = linalg.matrix4_translate_f32({-1, 0, 0})
  tail_apply(moved, {0, 1, 2}, state, {stiffness = 1, damping = 1}, 1.0 / 60.0, fresh = false)
  testing.expectf(t, moved.positions[2].x < -0.1, "tip trails the jump, got %v", moved.positions[2])
  for _ in 0 ..< 300 {
    moved = test_chain_pose(3)
    moved.root_world = linalg.matrix4_translate_f32({1, 0, 0})
    moved.root_inv = linalg.matrix4_translate_f32({-1, 0, 0})
    tail_apply(moved, {0, 1, 2}, state, {stiffness = 1, damping = 1}, 1.0 / 60.0, fresh = false)
  }
  testing.expectf(t, linalg.distance(moved.positions[2], [3]f32{0, 2, 0}) < 0.01, "settles back, got %v", moved.positions[2])
  testing.expectf(t, math.abs(linalg.distance(moved.positions[2], moved.positions[1]) - 1) < 1e-3, "rigid chain keeps length")
}

// leg ------------------------------------------------------------

@(private = "file")
leg_params :: proc(
  offset: [3]f32,
  lift_height: f32 = 0.5,
  lift_frequency: f32 = 2.0,
  lift_duration: f32 = 0.4,
  time_offset: f32 = 0.0,
) -> LegParams {
  return {offset = offset, lift_height = lift_height, lift_frequency = lift_frequency, lift_duration = lift_duration, time_offset = time_offset}
}

@(private = "file")
leg_at :: proc(p: LegParams) -> Leg {
  return {target = p.offset, foot = p.offset, last_target = p.offset}
}

@(test)
test_leg_grounded :: proc(t: ^testing.T) {
  p := leg_params({1, 0, 0})
  leg := leg_at(p)
  leg_step(&leg, p, 0.5)
  testing.expect_value(t, leg.foot, [3]f32{1, 0, 0})
}

@(test)
test_leg_lift_at_cycle_start :: proc(t: ^testing.T) {
  p := leg_params({0, 0, 0})
  leg := leg_at(p)
  leg.target = {1, 0, 0}
  leg_step(&leg, p, 0.1)
  testing.expect(t, leg.foot.y > 0, "foot lifted")
  testing.expect(t, leg.foot.x > 0 && leg.foot.x < 1, "foot moving horizontally")
}

@(test)
test_leg_lift_peaks_halfway :: proc(t: ^testing.T) {
  p := leg_params({0, 0, 0}, lift_height = 1)
  leg := leg_at(p)
  leg.target = {1, 0, 0}
  leg_step(&leg, p, 0.2)
  testing.expectf(t, math.abs(leg.foot.y - 1) < 1e-5, "lift_height at half the lift, got %v", leg.foot)
}

@(test)
test_leg_landing :: proc(t: ^testing.T) {
  p := leg_params({0, 0, 0})
  leg := leg_at(p)
  leg.target = {1, 0, 0}
  leg_step(&leg, p, 0.2)
  testing.expect(t, leg.foot.y > 0, "foot in the air")
  leg_step(&leg, p, 0.3)
  testing.expect_value(t, leg.foot, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.last_target, [3]f32{1, 0, 0})
}

@(test)
test_leg_time_offset :: proc(t: ^testing.T) {
  p1, p2 := leg_params({0, 0, 0}, time_offset = 0), leg_params({0, 0, 0}, time_offset = 1)
  leg1, leg2 := leg_at(p1), leg_at(p2)
  leg1.target = {1, 0, 0}
  leg2.target = {1, 0, 0}
  leg_step(&leg1, p1, 0.1)
  leg_step(&leg2, p2, 0.1)
  testing.expect(t, leg1.foot.y > 0, "leg 1 lifting")
  testing.expect_value(t, leg2.foot.y, 0.0)
}

@(test)
test_leg_retarget_mid_flight :: proc(t: ^testing.T) {
  p := leg_params({0, 0, 0})
  leg := leg_at(p)
  leg.target = {1, 0, 0}
  leg_step(&leg, p, 0.2)
  mid := leg.foot
  leg.target = {2, 0, 0}
  leg_step(&leg, p, 0.1)
  testing.expect(t, leg.foot.x > mid.x, "retargets toward the new spot")
}

@(test)
test_leg_zero_duration :: proc(t: ^testing.T) {
  p := leg_params({0, 0, 0}, lift_duration = 0)
  leg := leg_at(p)
  leg.target = {1, 0, 0}
  leg_step(&leg, p, 0.1)
  testing.expect_value(t, leg.foot, [3]f32{1, 0, 0})
}

@(test)
test_leg_skips_lift_for_nearby_target :: proc(t: ^testing.T) {
  p := leg_params({1, 0, 0})
  leg := leg_at(p)
  leg.target = {1.05, 0, 0}
  leg_step(&leg, p, 0.1)
  testing.expect_value(t, leg.foot, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.last_target, [3]f32{1, 0, 0})
}

@(test)
test_leg_target_leads_root_motion :: proc(t: ^testing.T) {
  p := leg_params({1, 0, 0}, lift_duration = 0.5)
  leg := leg_at(p)
  leg_follow(&leg, p, 0.1, {0, 0, 0})
  leg_follow(&leg, p, 0.1, {2, 0, 0})
  testing.expect_value(t, leg.target, [3]f32{13, 0, 0})
}

@(test)
test_leg_full_cycle :: proc(t: ^testing.T) {
  p := leg_params({0, 0, 0})
  leg := leg_at(p)
  leg.target = {1, 0, 0}
  leg_step(&leg, p, 0.2)
  testing.expect(t, leg.foot.y > 0, "lifting")
  leg_step(&leg, p, 0.3)
  testing.expect_value(t, leg.foot, [3]f32{1, 0, 0})
  leg_step(&leg, p, 1.5)
  testing.expect_value(t, leg.foot, [3]f32{1, 0, 0})
  leg.target = {2, 0, 0}
  leg_step(&leg, p, 0.2)
  testing.expect(t, leg.foot.y > 0, "lifts again next cycle")
}

@(test)
test_leg_apply_lifts_after_root_moves :: proc(t: ^testing.T) {
  p := leg_params({0, 0, 0})
  state := make([]f32, LEG_STATE, context.temp_allocator)
  pose := test_chain_pose(3, {1, 0, 0})
  leg_apply(pose, {0, 1, 2}, state, p, 0.1, fresh = true)
  pose = test_chain_pose(3, {1, 0, 0})
  pose.positions[0] = {1, 0, 0}
  leg_apply(pose, {0, 1, 2}, state, p, 0.1, fresh = false)
  testing.expect(t, leg_state(state).foot.y > 0, "foot lifted")
}

@(test)
test_leg_apply_short_chain_no_op :: proc(t: ^testing.T) {
  state := make([]f32, LEG_STATE, context.temp_allocator)
  pose := test_chain_pose(2)
  leg_apply(pose, {0}, state, leg_params({0, 0, 0}), 0.1, fresh = true)
  testing.expect(t, pose.positions[0] == {0, 0, 0})
}
