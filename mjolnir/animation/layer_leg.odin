package animation

import "core:math"
import "core:math/linalg"

// LegParams makes a leg step: its foot stays planted while the leg's root moves, then lifts
// and lands at a new spot ahead once per cycle. Its layer's bones are the leg, hip first,
// each bone the parent of the next (bone_chain); joint limits come from bone_limits. Run one
// layer per leg and shift time_offset to set the gait.
LegParams :: struct {
  offset:         [3]f32, // rest foot position relative to the leg's root, world space
  lift_height:    f32,
  lift_frequency: f32, // seconds per step cycle
  lift_duration:  f32, // seconds the foot is in the air per cycle
  time_offset:    f32, // phase shift of the step cycle
}

// A leg's state, world space.
@(private)
Leg :: struct {
  target:      [3]f32, // where the foot wants to be
  foot:        [3]f32, // where the foot is
  last_target: [3]f32, // where the foot last landed
  last_root:   [3]f32,
  time:        f32,
}

@(private)
LEG_STATE :: size_of(Leg) / size_of(f32)

// A foot does not lift for a target closer than this fraction of its offset.
@(private = "file")
LEG_MIN_STEP_RATIO :: f32(0.1)

@(private)
leg_state :: #force_inline proc(state: []f32) -> ^Leg {
  return (^Leg)(raw_data(state))
}

// Step the foot after the leg's root, then reach it with IK.
@(private)
leg_apply :: proc(pose: Pose, bones: []u32, state: []f32, params: LegParams, delta_time: f32, fresh: bool) {
  if len(bones) < 2 do return
  leg := leg_state(state)
  if fresh do leg^ = {target = params.offset, foot = params.offset, last_target = params.offset}
  root := pose.positions[bones[0]]
  leg_follow(leg, params, delta_time, to_world(pose, root))
  foot := to_model(pose, leg.foot)
  // pole above the leg's midpoint, perpendicular to the leg, so the knee bends up and out
  leg_dir := foot - root
  up := [3]f32{0, 1, 0}
  pole_offset := up
  if d2 := linalg.dot(leg_dir, leg_dir); d2 > 1e-8 do pole_offset = up - leg_dir * linalg.dot(up, leg_dir) / d2
  if linalg.length2(pole_offset) < 1e-8 do pole_offset = {1, 0, 0}
  pole := (root + foot) * 0.5 + linalg.normalize(pole_offset) * 2.0
  ik_solve(pose, bones, foot, pole, 0.8, 10, 0.01)
}

// Retarget the foot from the leg root's world position, leading it by the root's velocity,
// then step.
@(private)
leg_follow :: proc(self: ^Leg, params: LegParams, delta_time: f32, root: [3]f32) {
  root_velocity: [3]f32
  if self.time > 0 && delta_time > 0 do root_velocity = (root - self.last_root) / delta_time
  self.target = root + params.offset + root_velocity * params.lift_duration
  if self.time == 0 && delta_time > 0 {
    self.last_target = self.target
    self.foot = self.target
  }
  self.last_root = root
  leg_step(self, params, delta_time)
}

// Move the foot toward target: planted, or lifting along a parabola during the cycle's
// lift_duration, landing on target.
@(private)
leg_step :: proc(self: ^Leg, params: LegParams, delta_time: f32) {
  if params.lift_duration <= 0 {
    self.foot = self.target
    self.last_target = self.target
    return
  }
  min_step := linalg.length2(params.offset) * LEG_MIN_STEP_RATIO * LEG_MIN_STEP_RATIO
  if linalg.length2(self.target - self.last_target) <= min_step {
    self.time += delta_time
    self.foot = self.last_target
    return
  }
  prev_time := self.time
  self.time += delta_time
  if params.lift_frequency <= 0 {
    self.foot = self.target
    self.last_target = self.target
    return
  }
  phase := math.mod_f32(self.time + params.time_offset, params.lift_frequency)
  prev_phase := math.mod_f32(prev_time + params.time_offset, params.lift_frequency)
  lifting := phase < params.lift_duration
  was_lifting := prev_phase < params.lift_duration
  if lifting {
    t := phase / params.lift_duration
    // parabola: 0 at lift-off and landing, lift_height halfway
    self.foot = linalg.lerp(self.last_target, self.target, t) + {0, 4 * params.lift_height * t * (1 - t), 0}
  } else {
    self.foot = self.last_target
  }
  if was_lifting && !lifting {
    self.foot = self.target
    self.last_target = self.target
  }
}
