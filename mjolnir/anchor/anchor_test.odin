#+build !js
#+private file
package anchor

import "core:testing"

@(test)
test_frame_fits_one_axis :: proc(t: ^testing.T) {
	wide := frame({1024, 768}, {2048, 1000})
	testing.expect_value(t, wide.scale, 1000.0 / 768.0)
	testing.expect(t, wide.size.x > 1024)
	testing.expect_value(t, wide.size.y, 768)
	tall := frame({1024, 768}, {512, 800})
	testing.expect_value(t, tall.scale, 0.5)
	testing.expect_value(t, tall.size, [2]f32{1024, 1600})
	testing.expect_value(t, frame({1024, 768}, {0, 0}), Frame{1, {1024, 768}})
}

@(test)
test_fit_edges :: proc(t: ^testing.T) {
	r := Rect{{10, 20}, {100, 50}}
	from, to := [2]f32{400, 300}, [2]f32{500, 360}
	testing.expect_value(t, fit(r, {}, from, to), r)
	testing.expect_value(t, fit(r, {.LEFT, .TOP}, from, to), r)
	testing.expect_value(t, fit(r, {.RIGHT, .TOP}, from, to), Rect{{110, 20}, {100, 50}})
	testing.expect_value(t, fit(r, {.LEFT, .BOTTOM}, from, to), Rect{{10, 80}, {100, 50}})
	testing.expect_value(t, fit(r, {.STRETCH, .TOP}, from, to), Rect{{10, 20}, {200, 50}})
	testing.expect_value(t, fit(r, {.RIGHT, .STRETCH}, from, to), Rect{{110, 20}, {100, 110}})
}

@(test)
test_window_round_trip :: proc(t: ^testing.T) {
	f := frame({100, 100}, {200, 400})
	testing.expect_value(t, to_window(Rect{{10, 20}, {30, 40}}, f), Rect{{20, 40}, {60, 80}})
	testing.expect_value(t, to_reference({20, 40}, f), [2]f32{10, 20})
}
