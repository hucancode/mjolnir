#+private
package mech

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
near :: proc(a, b: [3]f32) -> bool {
  return linalg.length(a - b) < 1e-4
}

@(test)
test_chain_turns_about_each_axis :: proc(t: ^testing.T) {
  m: Mech
  init(&m)
  defer destroy(&m)
  append(&m.bones, make_bone(-1, axis = .Z, sign = 1))
  append(&m.bones, make_bone(0, offset = {1, 0, 0}))
  channels := []f32{math.PI / 2}
  poses := solve(&m, channels)
  testing.expect(t, near(poses[1].position, {0, 1, 0}))
  m.bones[0].axis = .Y
  poses = solve(&m, channels)
  testing.expect(t, near(poses[1].position, {0, 0, -1}))
  m.bones[0].axis = .X
  m.bones[1].offset = {0, 1, 0}
  poses = solve(&m, channels)
  testing.expect(t, near(poses[1].position, {0, 0, 1}))
}

@(test)
test_slide_moves_along_the_turned_axis :: proc(t: ^testing.T) {
  m: Mech
  init(&m, {0, 2, 0}, linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1}))
  defer destroy(&m)
  append(&m.bones, make_bone(-1, axis = .TX, sign = 1))
  poses := solve(&m, []f32{3})
  testing.expect(t, near(poses[0].position, {0, 5, 0}))
}

@(test)
test_limits_clamp_and_sign_zero_holds :: proc(t: ^testing.T) {
  m: Mech
  init(&m)
  defer destroy(&m)
  append(&m.bones, make_bone(-1, axis = .Z, sign = -1, lower = -0.5, upper = 0.5))
  append(&m.bones, make_bone(0, axis = .Z, channel = 1))
  channels := []f32{2, 1}
  testing.expect_value(t, value(&m, 0, channels), -0.5)
  testing.expect_value(t, value(&m, 1, channels), 0)
  m.bones[0].upper = m.bones[0].lower
  testing.expect_value(t, value(&m, 0, channels), -2)
}

@(test)
test_rest_applies_before_the_axis :: proc(t: ^testing.T) {
  m: Mech
  init(&m)
  defer destroy(&m)
  append(&m.bones, make_bone(-1, rest = linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1}), axis = .X, sign = 1))
  append(&m.bones, make_bone(0, offset = {0, 1, 0}))
  poses := solve(&m, []f32{math.PI / 2})
  testing.expect(t, near(poses[1].position, {0, 0, 1}))
}

@(test)
test_mirrored_chains_pose_mirrored :: proc(t: ^testing.T) {
  m: Mech
  init(&m)
  defer destroy(&m)
  for side in ([2]f32{-1, 1}) {
    root := len(m.bones)
    append(&m.bones, make_bone(-1, offset = {side, 0, 0}, axis = .X, channel = 0, sign = 1))
    append(&m.bones, make_bone(root, axis = .Z, channel = 1, sign = side))
    append(&m.bones, make_bone(root + 1, offset = {0, -1, 0}))
  }
  poses := solve(&m, []f32{0.4, 0.7})
  l, r := poses[2].position, poses[5].position
  testing.expect(t, near(l, {-r.x, r.y, r.z}))
}

@(test)
test_two_link_reaches :: proc(t: ^testing.T) {
  for target in ([][2]f32{{1.2, 0.3}, {0.5, -0.4}, {0.3, 0.9}}) {
    a, b, reached := two_link(1, 0.8, target)
    testing.expect(t, reached)
    testing.expect(t, b <= 0)
    tip := [2]f32{math.cos(a), math.sin(a)} + 0.8 * [2]f32{math.cos(a + b), math.sin(a + b)}
    testing.expect(t, linalg.length(tip - target) < 1e-4)
  }
  a, b, reached := two_link(1, 0.8, {3, 0})
  testing.expect(t, !reached)
  testing.expect(t, abs(a) < 1e-4 && abs(b) < 1e-4)
}

@(test)
test_seat_bolts_faces_together :: proc(t: ^testing.T) {
  parent := Face{{1, 0, 0}, {1, 0, 0}, {0, 0, 1}}
  child := Face{{0, 0.5, 0}, {0, 1, 0}, {1, 0, 0}}
  position, rotation := seat(parent, child)
  testing.expect(t, near(position + linalg.quaternion128_mul_vector3(rotation, child.position), parent.position))
  testing.expect(t, near(linalg.quaternion128_mul_vector3(rotation, child.normal), -parent.normal))
  testing.expect(t, near(linalg.quaternion128_mul_vector3(rotation, child.forward), parent.forward))
}
