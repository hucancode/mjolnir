package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

almost_equal_quaternion :: proc(a, b: quaternion128, eps: f32 = 1e-5) -> bool {
  return(
    abs(a.x - b.x) <= eps &&
    abs(a.y - b.y) <= eps &&
    abs(a.z - b.z) <= eps &&
    abs(a.w - b.w) <= eps \
  )
}

almost_equal_vec3 :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool {
  return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps && abs(a.z - b.z) <= eps
}

// ---------- track_sample ----------

@(test)
test_track_linear_f32 :: proc(t: ^testing.T) {
  tr := Track(f32){times = {0, 1}, values = {0, 10}, interpolation = .LINEAR}
  testing.expect_value(t, track_sample(tr, 0.5, 0), 5)
  testing.expect_value(t, track_sample(tr, 0.25, 0), 2.5)
  testing.expect_value(t, track_duration(tr), 1)
}

@(test)
test_track_linear_vec3 :: proc(t: ^testing.T) {
  tr := Track([3]f32) {
    times  = {0, 1, 2},
    values = {{0, 0, 0}, {1, 2, 3}, {2, 4, 6}},
  }
  testing.expect_value(t, track_sample(tr, 0, [3]f32{}), [3]f32{0, 0, 0})
  testing.expect_value(t, track_sample(tr, 1, [3]f32{}), [3]f32{1, 2, 3})
  testing.expect_value(t, track_sample(tr, 2, [3]f32{}), [3]f32{2, 4, 6})
  testing.expect_value(t, track_sample(tr, 0.5, [3]f32{}), [3]f32{0.5, 1, 1.5})
  testing.expect_value(t, track_sample(tr, 1.5, [3]f32{}), [3]f32{1.5, 3, 4.5})
  testing.expect_value(t, track_sample(tr, -1, [3]f32{}), [3]f32{0, 0, 0})
  testing.expect_value(t, track_sample(tr, 3, [3]f32{}), [3]f32{2, 4, 6})
}

@(test)
test_track_linear_quaternion_slerp :: proc(t: ^testing.T) {
  q1 := linalg.QUATERNIONF32_IDENTITY
  q2 := linalg.quaternion_angle_axis_f32(math.PI / 2, linalg.VECTOR3F32_Z_AXIS)
  q3 := linalg.quaternion_angle_axis_f32(math.PI, linalg.VECTOR3F32_Y_AXIS)
  tr := Track(quaternion128){times = {0, 1, 2}, values = {q1, q2, q3}}
  id := linalg.QUATERNIONF32_IDENTITY
  testing.expect(t, almost_equal_quaternion(track_sample(tr, 0, id), q1))
  testing.expect(t, almost_equal_quaternion(track_sample(tr, 1, id), q2))
  testing.expect(t, almost_equal_quaternion(track_sample(tr, 2, id), q3))
  half := linalg.quaternion_angle_axis_f32(math.PI / 4, linalg.VECTOR3F32_Z_AXIS)
  testing.expect(t, almost_equal_quaternion(track_sample(tr, 0.5, id), half))
}

@(test)
test_track_step :: proc(t: ^testing.T) {
  tr := Track(f32){times = {0, 1, 2}, values = {0, 10, 20}, interpolation = .STEP}
  testing.expect_value(t, track_sample(tr, 0.0, 0), 0)
  testing.expect_value(t, track_sample(tr, 0.5, 0), 0)
  testing.expect_value(t, track_sample(tr, 0.99, 0), 0)
  testing.expect_value(t, track_sample(tr, 1.0, 0), 10)
  testing.expect_value(t, track_sample(tr, 1.5, 0), 10)
  testing.expect_value(t, track_sample(tr, 1.99, 0), 10)
  testing.expect_value(t, track_sample(tr, 2.0, 0), 20)
  testing.expect_value(t, track_sample(tr, 3.0, 0), 20)
}

@(test)
test_track_empty_returns_fallback :: proc(t: ^testing.T) {
  tr: Track(f32)
  testing.expect_value(t, track_sample(tr, 0.5, 0), 0)
  testing.expect_value(t, track_sample(tr, 0.5, 999), 999)
  testing.expect_value(t, track_duration(tr), 0)
}

@(test)
test_track_single_key :: proc(t: ^testing.T) {
  for interp in Interpolation {
    tr := Track(f32){times = {1}, values = {42}, interpolation = interp}
    if interp == .CUBIC do tr.values = {-1, 42, -1}
    testing.expect_value(t, track_sample(tr, 0, 0), 42)
    testing.expect_value(t, track_sample(tr, 1, 0), 42)
    testing.expect_value(t, track_sample(tr, 2, 0), 42)
  }
}

@(test)
test_track_clamps_and_exact_keys :: proc(t: ^testing.T) {
  tr := Track(f32){times = {0, 1}, values = {2, 4}}
  testing.expect_value(t, track_sample(tr, -1, 0), 2)
  testing.expect_value(t, track_sample(tr, 2, 0), 4)
  testing.expect_value(t, track_sample(tr, 0, 0), 2)
  testing.expect_value(t, track_sample(tr, 1, 0), 4)
  // interior exact key time on a longer track
  tr3 := Track(f32){times = {0, 1, 2, 3}, values = {0, 7, 3, 9}}
  testing.expect_value(t, track_sample(tr3, 1, 0), 7)
  testing.expect_value(t, track_sample(tr3, 2, 0), 3)
}

@(test)
test_track_cubic_f32 :: proc(t: ^testing.T) {
  // per key: in-tangent, value, out-tangent
  tr := Track(f32){times = {0, 1}, values = {0, 0, 5, 5, 10, 0}, interpolation = .CUBIC}
  testing.expect_value(t, track_sample(tr, 0, 0), 0)
  testing.expect_value(t, track_sample(tr, 1, 0), 10)
  // hermite at u=0.5: 0.5*p0 + 0.125*m0 + 0.5*p1 - 0.125*m1 = 0 + 0.625 + 5 - 0.625
  mid := track_sample(tr, 0.5, 0)
  testing.expectf(t, abs(mid - 5) < 1e-5, "mid=%f", mid)
  // tangents matter: out-tangent of key 0 pulls the curve up early
  tr2 := Track(f32){times = {0, 1}, values = {0, 0, 20, 0, 10, 0}, interpolation = .CUBIC}
  q := track_sample(tr2, 0.25, 0)
  lin := f32(2.5)
  testing.expectf(t, q > lin, "out-tangent should lift the curve, got %f", q)
}

@(test)
test_track_cubic_vec3 :: proc(t: ^testing.T) {
  tr := Track([3]f32) {
    times         = {0, 1},
    values        = {{0, 0, 0}, {0, 0, 0}, {1, 2, 3}, {1, 2, 3}, {10, 20, 30}, {0, 0, 0}},
    interpolation = .CUBIC,
  }
  testing.expect_value(t, track_sample(tr, 0, [3]f32{}), [3]f32{0, 0, 0})
  testing.expect_value(t, track_sample(tr, 1, [3]f32{}), [3]f32{10, 20, 30})
  mid := track_sample(tr, 0.5, [3]f32{})
  testing.expect(t, mid.x > 0 && mid.x < 10)
  testing.expect(t, mid.y > 0 && mid.y < 20)
  testing.expect(t, mid.z > 0 && mid.z < 30)
}

@(test)
test_track_cubic_quaternion :: proc(t: ^testing.T) {
  q1 := linalg.QUATERNIONF32_IDENTITY
  q2 := linalg.quaternion_angle_axis_f32(math.PI / 2, linalg.VECTOR3F32_Z_AXIS)
  tan: quaternion128 = quaternion(w = 0, x = 0, y = 0, z = 0.5)
  tr := Track(quaternion128){times = {0, 1}, values = {tan, q1, tan, tan, q2, tan}, interpolation = .CUBIC}
  id := linalg.QUATERNIONF32_IDENTITY
  testing.expect(t, almost_equal_quaternion(track_sample(tr, 0, id), q1))
  testing.expect(t, almost_equal_quaternion(track_sample(tr, 1, id), q2))
  mid := track_sample(tr, 0.5, id)
  len2 := mid.w * mid.w + mid.x * mid.x + mid.y * mid.y + mid.z * mid.z
  testing.expectf(t, abs(len2 - 1) < 1e-4, "normalized, len2=%f", len2)
  testing.expect(t, mid.z > 0 && mid.z < q2.z, "between endpoints")
}

@(test)
test_track_sample_cheap_benchmark :: proc(t: ^testing.T) {
  N :: 4096
  times := make([]f32, N)
  values := make([]f32, N)
  defer delete(times)
  defer delete(values)
  for i in 0 ..< N {
    times[i] = f32(i) * 0.01
    values[i] = f32(i)
  }
  tr := Track(f32){times = times, values = values}
  sum: f32
  for i in 0 ..< 100_000 do sum += track_sample(tr, f32(i % 4000) * 0.01 + 0.005, 0)
  testing.expect(t, sum > 0)
  // binary search finds the right segment
  testing.expect(t, abs(track_sample(tr, 12.345, 0) - 1234.5) < 1e-2)
}

// ---------- clip ----------

@(test)
test_clip_init_and_set :: proc(t: ^testing.T) {
  clip: Clip
  clip_init(&clip, 2, "walk")
  defer clip_destroy(&clip)
  testing.expect_value(t, clip.name, "walk")
  testing.expect_value(t, len(clip.channels), 2)
  testing.expect_value(t, clip.duration, 0)
  clip_set_positions(&clip, 0, {0, 1}, {{0, 0, 0}, {10, 0, 0}})
  q := linalg.quaternion_angle_axis_f32(math.PI / 2, linalg.VECTOR3F32_Z_AXIS)
  clip_set_rotations(&clip, 0, {0, 2}, {linalg.QUATERNIONF32_IDENTITY, q})
  clip_set_scales(&clip, 0, {0, 1.5}, {{1, 1, 1}, {2, 2, 2}})
  testing.expect_value(t, clip.duration, 2)

  p, r, s := clip_sample_channel(&clip, 0, 0.5)
  pv, pok := p.?
  rv, rok := r.?
  sv, sok := s.?
  testing.expect(t, pok && rok && sok)
  testing.expect_value(t, pv, [3]f32{5, 0, 0})
  testing.expect(t, almost_equal_quaternion(rv, linalg.quaternion_angle_axis_f32(math.PI / 8, linalg.VECTOR3F32_Z_AXIS)))
  testing.expect(t, almost_equal_vec3(sv, {4.0 / 3, 4.0 / 3, 4.0 / 3}))
}

@(test)
test_clip_duration_grows :: proc(t: ^testing.T) {
  clip: Clip
  clip_init(&clip, 2, duration = 0.5)
  defer clip_destroy(&clip)
  testing.expect_value(t, clip.duration, 0.5)
  clip_set_positions(&clip, 0, {0, 3}, {{0, 0, 0}, {1, 1, 1}})
  testing.expect_value(t, clip.duration, 3)
  clip_set_positions(&clip, 1, {0, 1}, {{0, 0, 0}, {1, 1, 1}})
  testing.expect_value(t, clip.duration, 3)
}

@(test)
test_clip_sample_channel_unanimated_nil :: proc(t: ^testing.T) {
  clip: Clip
  clip_init(&clip, 2)
  defer clip_destroy(&clip)
  clip_set_positions(&clip, 0, {0, 1}, {{0, 0, 0}, {1, 0, 0}})
  p, r, s := clip_sample_channel(&clip, 0, 0.5)
  _, pok := p.?
  _, rok := r.?
  _, sok := s.?
  testing.expect(t, pok && !rok && !sok)
  p, r, s = clip_sample_channel(&clip, 1, 0.5)
  _, pok = p.?
  testing.expect(t, !pok, "channel 1 not animated")
  p, r, s = clip_sample_channel(&clip, 5, 0.5)
  _, pok = p.?
  testing.expect(t, !pok, "out-of-range channel")
}

@(test)
test_clip_sample_trs_keeps_unanimated :: proc(t: ^testing.T) {
  clip: Clip
  clip_init(&clip, 1)
  defer clip_destroy(&clip)
  clip_set_positions(&clip, 0, {0, 1}, {{0, 0, 0}, {10, 0, 0}})
  q := linalg.quaternion_angle_axis_f32(0.3, linalg.VECTOR3F32_X_AXIS)
  out := TRS{position = {7, 7, 7}, rotation = q, scale = {3, 3, 3}}
  clip_sample_trs(&clip, 0, 1, &out)
  testing.expect_value(t, out.position, [3]f32{10, 0, 0})
  testing.expect(t, out.rotation == q, "rotation untouched")
  testing.expect_value(t, out.scale, [3]f32{3, 3, 3})
}

@(test)
test_clip_flat_arrays_shared :: proc(t: ^testing.T) {
  clip: Clip
  clip_init(&clip, 2)
  defer clip_destroy(&clip)
  clip_set_positions(&clip, 0, {0, 1}, {{0, 0, 0}, {1, 0, 0}})
  clip_set_positions(&clip, 1, {0, 0.5, 2}, {{0, 0, 0}, {0, 5, 0}, {0, 9, 0}}, .STEP)
  testing.expect_value(t, len(clip.times), 5)
  testing.expect_value(t, len(clip.positions), 5)
  r0 := clip.channels[0].position
  r1 := clip.channels[1].position
  testing.expect(t, r0.time_offset == 0 && r0.value_offset == 0 && r0.count == 2 && r0.interpolation == .LINEAR)
  testing.expect(t, r1.time_offset == 2 && r1.value_offset == 2 && r1.count == 3 && r1.interpolation == .STEP)
  tr1 := clip_position_track(&clip, 1)
  testing.expect_value(t, len(tr1.times), 3)
  testing.expect_value(t, tr1.times[1], 0.5)
  testing.expect_value(t, tr1.values[2], [3]f32{0, 9, 0})
  p0, _, _ := clip_sample_channel(&clip, 0, 0.5)
  p1, _, _ := clip_sample_channel(&clip, 1, 1)
  testing.expect_value(t, p0.?, [3]f32{0.5, 0, 0})
  testing.expect_value(t, p1.?, [3]f32{0, 5, 0})
}

@(test)
test_clip_cubic_range :: proc(t: ^testing.T) {
  clip: Clip
  clip_init(&clip, 2)
  defer clip_destroy(&clip)
  clip_set_positions(&clip, 0, {0, 1}, {{}, {0, 0, 0}, {}, {}, {4, 0, 0}, {}}, .CUBIC)
  clip_set_positions(&clip, 1, {0, 1}, {{1, 0, 0}, {2, 0, 0}})
  testing.expect_value(t, clip.channels[1].position.value_offset, 6)
  testing.expect_value(t, len(clip_position_track(&clip, 0).values), 6)
  p0, _, _ := clip_sample_channel(&clip, 0, 1)
  p1, _, _ := clip_sample_channel(&clip, 1, 0.5)
  testing.expect_value(t, p0.?, [3]f32{4, 0, 0})
  testing.expect_value(t, p1.?, [3]f32{1.5, 0, 0})
}

// ---------- playback ----------

@(test)
test_playback_once_stops_at_end :: proc(t: ^testing.T) {
  time, speed: f32 = 0.0, 1.0
  status := Status.PLAYING
  for _ in 0 ..< 5 do playback_advance(&time, &speed, &status, .ONCE, 1.0, 0.3)
  testing.expect_value(t, time, 1.0)
  testing.expect_value(t, status, Status.STOPPED)
  playback_advance(&time, &speed, &status, .ONCE, 1.0, 0.3)
  testing.expect_value(t, time, 1.0)
}

@(test)
test_playback_loop_wraps :: proc(t: ^testing.T) {
  time, speed: f32 = 0.0, 1.0
  status := Status.PLAYING
  playback_advance(&time, &speed, &status, .LOOP, 1.0, 1.25)
  testing.expect(t, abs(time - 0.25) < 1e-5)
  testing.expect_value(t, status, Status.PLAYING)
  playback_advance(&time, &speed, &status, .LOOP, 1.0, 0.7)
  playback_advance(&time, &speed, &status, .LOOP, 1.0, 0.5)
  testing.expectf(t, abs(time - 0.45) < 1e-5, "got %f", time)
}

@(test)
test_playback_ping_pong :: proc(t: ^testing.T) {
  time, speed: f32 = 0.0, 1.0
  status := Status.PLAYING
  playback_advance(&time, &speed, &status, .PING_PONG, 1.0, 1.5)
  testing.expect(t, speed < 0, "speed reversed past duration")
  before := time
  playback_advance(&time, &speed, &status, .PING_PONG, 1.0, 0.25)
  testing.expect(t, time < before, "now moving backwards")
  testing.expect_value(t, status, Status.PLAYING)
}

@(test)
test_playback_paused :: proc(t: ^testing.T) {
  time, speed: f32 = 0.3, 1.0
  status := Status.PAUSED
  playback_advance(&time, &speed, &status, .LOOP, 1.0, 0.5)
  testing.expect_value(t, time, 0.3)
  status = .STOPPED
  playback_advance(&time, &speed, &status, .LOOP, 1.0, 0.5)
  testing.expect_value(t, time, 0.3)
}
