#+build !js
#+private
package physics

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
STEP :: 1.0 / 60.0

@(private = "file")
run :: proc(w: ^World, seconds: f32) {
  for _ in 0 ..< int(seconds / STEP) do step(w, STEP)
}

@(test)
test_world_anchor_pendulum_keeps_length :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  bob := body_create(&w, {2, 5, 0}, collider = SphereCollider{radius = 0.2}, mass = 1)
  joint_create(&w, bob, {}, BallJoint{anchor = {0, 5, 0}})
  for _ in 0 ..< 180 {
    step(&w, STEP)
    p := body(&w, bob).position - [3]f32{0, 5, 0}
    testing.expect(t, math.abs(linalg.length(p) - 2) < 0.05, "rod length drifted")
  }
  testing.expect(t, body(&w, bob).position.y < 4.5, "bob did not swing down")
}

@(test)
test_joint_anchor_drags_body :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  b := body_create(&w, {0, 5, 0}, collider = BoxCollider{half_extents = {0.3, 0.3, 0.3}}, mass = 1)
  j := joint_create(&w, b, {}, BallJoint{anchor = {0, 5, 0}})
  joint_anchor(&w, j, {3, 8, 0})
  run(&w, 2)
  testing.expect(t, linalg.length(body(&w, b).position - [3]f32{3, 8, 0}) < 0.5, "body did not follow the anchor")
}

@(test)
test_ball_chain_stays_connected :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  body_create(&w, {0, -0.5, 0}, collider = BoxCollider{half_extents = {20, 0.5, 20}})
  prev: BodyHandle
  for i in 0 ..< 6 {
    y := 6 - f32(i) * 0.6
    h := body_create(&w, {0, y, 0}, collider = BoxCollider{half_extents = {0.1, 0.3, 0.1}}, mass = 1)
    joint_create(&w, h, prev, BallJoint{anchor = {0, y + 0.3, 0}})
    prev = h
  }
  run(&w, 3)
  for j in joint_list(&w) {
    a := body(&w, j.body_a)
    b := body(&w, j.body_b)
    if j.body_b == {} do continue
    pa := a.position + linalg.quaternion128_mul_vector3(a.rotation, j.local_a)
    pb := b.position + linalg.quaternion128_mul_vector3(b.rotation, j.local_b)
    testing.expect(t, linalg.length(pa - pb) < 0.05, "chain link separated")
  }
}

@(test)
test_hinge_respects_limits :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  top := body_create(&w, {0, 5, 0}, collider = BoxCollider{half_extents = {0.2, 0.2, 0.2}})
  arm := body_create(&w, {1, 5, 0}, collider = BoxCollider{half_extents = {1, 0.1, 0.1}}, mass = 1)
  joint_create(&w, arm, top, HingeJoint{anchor = {0, 5, 0}, axis = {0, 0, 1}, lower = -0.5, upper = 0.5})
  run(&w, 3)
  a := body(&w, arm)
  forward := linalg.quaternion128_mul_vector3(a.rotation, [3]f32{1, 0, 0})
  angle := math.atan2(forward.y, forward.x)
  testing.expectf(t, angle > -0.6 && angle < 0.05, "hinge angle %v outside limit", angle)
  testing.expect(t, math.abs(forward.z) < 0.05, "hinge left its plane")
}

@(test)
test_cone_limit_holds :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  top := body_create(&w, {0, 5, 0}, collider = BoxCollider{half_extents = {0.2, 0.2, 0.2}})
  arm := body_create(&w, {0, 4, 0}, collider = BoxCollider{half_extents = {0.1, 0.5, 0.1}}, mass = 1)
  joint_create(&w, arm, top, BallJoint{anchor = {0, 5, 0}, axis = {0, -1, 0}, cone = 0.6})
  set_velocity(&w, arm, {6, 0, 0})
  run(&w, 2)
  dir := linalg.quaternion128_mul_vector3(body(&w, arm).rotation, [3]f32{0, -1, 0})
  angle := math.acos(clamp(dir.y * -1, -1, 1))
  testing.expectf(t, angle < 0.75, "cone exceeded: %v", angle)
}

@(test)
test_jointed_pair_does_not_collide :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  a := body_create(&w, {0, 0, 0}, collider = BoxCollider{half_extents = {1, 1, 1}}, mass = 1)
  b := body_create(&w, {0.5, 0, 0}, collider = BoxCollider{half_extents = {1, 1, 1}}, mass = 1)
  w.gravity = {}
  step(&w, STEP)
  testing.expect(t, len(contacts(&w)) == 1, "overlapping boxes should touch")
  joint_create(&w, a, b, BallJoint{anchor = {0.25, 0, 0}})
  step(&w, STEP)
  testing.expect(t, len(contacts(&w)) == 0, "jointed boxes still collide")
}

@(test)
test_destroy_body_removes_joint :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  a := body_create(&w, {0, 5, 0}, collider = SphereCollider{radius = 0.5}, mass = 1)
  b := body_create(&w, {0, 4, 0}, collider = SphereCollider{radius = 0.5}, mass = 1)
  joint_create(&w, a, b, BallJoint{anchor = {0, 4.5, 0}})
  joint_create(&w, b, {}, BallJoint{anchor = {0, 4, 0}})
  testing.expect(t, w.joint_slots.count == 2)
  body_destroy(&w, b)
  testing.expect(t, w.joint_slots.count == 0, "joints of a destroyed body must go")
  step(&w, STEP)
}

@(test)
test_jointed_chain_sleeps_as_one :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  body_create(&w, {0, -0.5, 0}, collider = BoxCollider{half_extents = {20, 0.5, 20}})
  a := body_create(&w, {0, 0.5, 0}, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 1)
  b := body_create(&w, {1.2, 0.5, 0}, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 1)
  joint_create(&w, a, b, BallJoint{anchor = {0.6, 0.5, 0}})
  run(&w, 6)
  testing.expect(t, body(&w, a).is_sleeping && body(&w, b).is_sleeping, "chain should sleep together")
}

@(private = "file")
joint_list :: proc(w: ^World) -> []JointData {
  out := make([dynamic]JointData, context.temp_allocator)
  for i in 0 ..< int(w.joint_slots.high_water) {
    if w.joint_slots.live[i / 64] & (1 << u32(i % 64)) != 0 do append(&out, w.joints[i])
  }
  return out[:]
}

@(test)
test_step_limits_delta_time :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  w.gravity = {0, -10, 0}
  b := body_create(&w, {0, 100, 0}, collider = SphereCollider{radius = 0.5}, mass = 1)
  step(&w, 5)
  fallen := 100 - body(&w, b).position.y
  testing.expectf(t, fallen < 1, "a 5s step simulated %v m of fall", fallen)
}
