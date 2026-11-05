#+build !js
#+private
package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

// A signal that is its own time: what a link reads is how long before t it read.
@(private = "file")
clock_source :: proc(data: rawptr, t: f32, out: []f32) {
  for &v in out do v = t
}

@(test)
test_lag_sample_follows_and_leads :: proc(t: ^testing.T) {
  src := LagSource{sample = clock_source}
  out: [1]f32
  // one read: link k at t - delay - k * step
  lag_sample(Lag{delay = 0.1, step = 0.2}, 2, 1, src, out[:])
  testing.expectf(t, abs(out[0] - (1 - 0.1 - 0.4)) < 1e-6, "one read: %v", out[0])
  // a window: the average of reads at its quarters, j = 1 to 4
  lag_sample(Lag{step = 0.1, window = 0.1, samples = 4}, 1, 1, src, out[:])
  want: f32 = 1 - 0.1 - 0.1 * (1 + 2 + 3 + 4) / 16
  testing.expectf(t, abs(out[0] - want) < 1e-6, "windowed: %v, want %v", out[0], want)
  // negative: it leads
  lag_sample(Lag{delay = -0.25}, 0, 1, src, out[:])
  testing.expectf(t, abs(out[0] - 1.25) < 1e-6, "leads: %v", out[0])
}

@(test)
test_lag_history :: proc(t: ^testing.T) {
  h := lag_history_make(4, 1)
  defer lag_history_destroy(&h)
  out: [1]f32
  lag_read(&h, Lag{}, 0, 1, out[:])
  testing.expect_value(t, out[0], 0)
  for k in 0 ..< 10 do lag_record(&h, f32(k), []f32{2 * f32(k)})
  // frames 6 to 9 are kept: between two it is between their values, past either end the end's
  lag_at(&h, 7.5, out[:])
  testing.expectf(t, abs(out[0] - 15) < 1e-6, "between frames: %v", out[0])
  lag_at(&h, 2, out[:])
  testing.expect_value(t, out[0], 12)
  lag_at(&h, 20, out[:])
  testing.expect_value(t, out[0], 18)
  // link 1 a frame behind link 0
  lag_read(&h, Lag{step = 1}, 1, 9, out[:])
  testing.expect_value(t, out[0], 16)
}

// A follow layer on the wave clip's two bones: the first (link 0, no delay) turns as the clip
// does, the second as the clip turned it a step before, and both catch up once the clip holds.
@(test)
test_follow_layer :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "wave", .ONCE)
  follow, ok := layer_create(&a, &rig, FollowParams{lag = Lag{step = 0.2}}, []u32{1, 2})
  testing.expect(t, ok)
  id := linalg.QUATERNIONF32_IDENTITY
  q90 := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1})
  for _ in 0 ..< 10 do animator_update(&a, &rig, 0.05)
  testing.expectf(t, almost_equal_quaternion(a.local[1].rotation, linalg.quaternion_slerp(id, q90, 0.5), 1e-3), "link 0 on the clip: %v", a.local[1].rotation)
  testing.expectf(t, almost_equal_quaternion(a.local[2].rotation, linalg.quaternion_slerp(id, q90, 0.3), 1e-3), "link 1 where the clip was 0.2 before: %v", a.local[2].rotation)
  // its children ride on it
  want := a.positions[2] + linalg.mul(a.rotations[2], [3]f32{0, 1, 0})
  testing.expect(t, almost_equal_vec3(a.positions[3], want), "the bone below follows")
  for _ in 0 ..< 20 do animator_update(&a, &rig, 0.05)
  testing.expect(t, almost_equal_quaternion(a.local[2].rotation, q90, 1e-3), "settled once the clip holds")
  layer_destroy(&a, follow)
}
