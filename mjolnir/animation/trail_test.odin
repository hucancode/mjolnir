#+build !js
#+private
package animation

import "core:testing"

@(test)
test_trail_samples_the_path_travelled :: proc(t: ^testing.T) {
  trail: Trail([2]f32)
  trail_init(&trail, {0, 0}, {0, 1}, 4, 0.5)
  defer trail_destroy(&trail)
  trail_move(&trail, {2, 0})
  trail_move(&trail, {2, 1})
  testing.expect_value(t, trail_sample(trail, 0), [2]f32{2, 1})
  testing.expect_value(t, trail_sample(trail, 0.5), [2]f32{2, 0.5})
  testing.expect_value(t, trail_sample(trail, 1), [2]f32{2, 0})
  testing.expect_value(t, trail_sample(trail, 2), [2]f32{1, 0})
  testing.expect_value(t, trail_sample(trail, 3), [2]f32{0, 0})
}

@(test)
test_trail_starts_straight_behind_the_head :: proc(t: ^testing.T) {
  trail: Trail([3]f32)
  trail_init(&trail, {1, 0, 1}, {0, 0, 1}, 2, 0.5)
  defer trail_destroy(&trail)
  testing.expect_value(t, trail_sample(trail, 1), [3]f32{1, 0, 2})
  testing.expect_value(t, trail_sample(trail, 100), trail.points[len(trail.points) - 1])
}
