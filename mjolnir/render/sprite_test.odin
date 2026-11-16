#+build !js
#+private file
package render

import "core:testing"

@(test)
test_sprite_clip_loops_or_holds :: proc(t: ^testing.T) {
	loop := SpriteClip{first = 10, count = 4, fps = 10}
	f, done := sprite_clip_frame(loop, 0.55)
	testing.expect_value(t, f, 15 - 4)
	testing.expect(t, !done)
	once := SpriteClip{first = 10, count = 4, fps = 10, once = true}
	f, done = sprite_clip_frame(once, 0.25)
	testing.expect_value(t, f, 12)
	testing.expect(t, !done)
	f, done = sprite_clip_frame(once, 0.9)
	testing.expect_value(t, f, 13)
	testing.expect(t, done)
}

@(test)
test_sprite_frames_grid_cells_row_major :: proc(t: ^testing.T) {
	frames := sprite_frames_grid(4, 2, {2, 3})
	testing.expect_value(t, len(frames), 8)
	// cell 5: column 1, row 1
	f := frames[5]
	testing.expect_value(t, f.uv[0], [2]f32{0.25, 0.5})
	testing.expect_value(t, f.uv[2], [2]f32{0.5, 1})
	testing.expect_value(t, f.uv[1], [2]f32{0.5, 0.5})
	testing.expect_value(t, f.uv[3], [2]f32{0.25, 1})
	testing.expect_value(t, f.size, [2]f32{2, 3})
}
