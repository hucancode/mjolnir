#+build !js
#+private file
package ui

import "../font"
import "core:testing"

TEST_FONT :: #load("../../assets/Outfit-Regular.ttf")

// The skin used below: a 50 x 50 texel region, cut 10 texels in on every side, so its middle is
// 30 texels long.
SKIN :: Skin{image = 7, size = {50, 50}, border = {10, 10, 10, 10}}

// The x of each quad's left edge and the u of its right edge, along the top row.
top_row :: proc(c: ^Canvas) -> (lefts: [dynamic]f32, us: [dynamic]f32) {
	vertices, _, _ := mesh(c)
	for q := 0; q + 3 < len(vertices); q += 4 {
		if vertices[q].pos.y != 0 do continue
		append(&lefts, vertices[q].pos.x)
		append(&us, vertices[q + 1].uv.x)
	}
	return
}

@(test)
test_batches_break_on_texture_z_and_clip :: proc(t: ^testing.T) {
	c: Canvas
	defer destroy(&c)
	rect(&c, {{0, 0}, {10, 10}}, WHITE)
	rect(&c, {{10, 0}, {10, 10}}, WHITE)
	rect(&c, {{0, 0}, {10, 10}}, WHITE, texture = 3)
	c.z = 2
	rect(&c, {{0, 0}, {10, 10}}, WHITE, texture = 3)
	c.clip = {{0, 0}, {5, 5}}
	rect(&c, {{0, 0}, {10, 10}}, WHITE, texture = 3)
	_, _, batches := mesh(&c)
	testing.expect_value(t, len(batches), 4)
	testing.expect_value(t, batches[0].index_count, 12)
	testing.expect_value(t, batches[2].z, 2)
	testing.expect_value(t, batches[3].clip, Rect{{0, 0}, {5, 5}})
	reset(&c)
	vertices, _, after := mesh(&c)
	testing.expect(t, len(vertices) == 0 && len(after) == 0 && c.z == 0, "reset empties it")
}

@(test)
test_rect_snaps_to_framebuffer_pixels :: proc(t: ^testing.T) {
	c := Canvas{dpi = 2}
	defer destroy(&c)
	rect(&c, {{0.3, 0}, {10, 10}}, WHITE)
	vertices, _, _ := mesh(&c)
	testing.expect_value(t, vertices[0].pos.x, 0.5)
	testing.expect_value(t, vertices[1].pos.x, 10.5)
}

@(test)
test_skin_stretch_keeps_its_corners :: proc(t: ^testing.T) {
	c: Canvas
	defer destroy(&c)
	skin(&c, {{0, 0}, {100, 60}}, SKIN)
	vertices, _, batches := mesh(&c)
	testing.expect_value(t, len(batches), 1)
	testing.expect_value(t, batches[0].texture, 7)
	testing.expect_value(t, batches[0].vertex_count, 9 * 4)
	// the top-left corner: 10 x 10, the region's first fifth
	testing.expect_value(t, vertices[2].pos, [2]f32{10, 10})
	testing.expect_value(t, vertices[2].uv, [2]f32{0.2, 0.2})
	// the middle stretches
	testing.expect_value(t, vertices[4 * 4].pos, [2]f32{10, 10})
	testing.expect_value(t, vertices[4 * 4 + 2].pos, [2]f32{90, 50})
	testing.expect_value(t, vertices[4 * 4 + 2].uv, [2]f32{0.8, 0.8})
}

@(test)
test_skin_scale_and_shrink :: proc(t: ^testing.T) {
	c: Canvas
	defer destroy(&c)
	s := SKIN
	s.scale = 2
	skin(&c, {{0, 0}, {100, 100}}, s)
	vertices, _, _ := mesh(&c)
	testing.expect_value(t, vertices[2].pos, [2]f32{20, 20})
	reset(&c)
	// cuts 40 wide on a 30 wide rect meet in the middle
	skin(&c, {{0, 0}, {30, 100}}, s)
	vertices, _, _ = mesh(&c)
	testing.expect_value(t, vertices[2].pos.x, 15)
}

@(test)
test_skin_repeat_cuts_the_last_tile :: proc(t: ^testing.T) {
	c: Canvas
	defer destroy(&c)
	s := SKIN
	s.mode = {.REPEAT, .STRETCH}
	// a 100 long middle of 30 long tiles: 3 whole and a third
	skin(&c, {{0, 0}, {120, 60}}, s)
	lefts, us := top_row(&c)
	defer delete(lefts)
	defer delete(us)
	testing.expect_value(t, len(lefts), 6)
	testing.expect_value(t, lefts[1], 10)
	testing.expect_value(t, lefts[2], 40)
	testing.expect_value(t, lefts[4], 100)
	testing.expect_value(t, us[3], 0.8)
	testing.expect(t, abs(us[4] - (0.2 + 0.6 / 3)) < 1e-4, "the last tile shows a third of the middle")
}

@(test)
test_skin_round_fits_whole_tiles :: proc(t: ^testing.T) {
	c: Canvas
	defer destroy(&c)
	s := SKIN
	s.mode = {.ROUND, .STRETCH}
	skin(&c, {{0, 0}, {120, 60}}, s)
	lefts, us := top_row(&c)
	defer delete(lefts)
	defer delete(us)
	testing.expect_value(t, len(lefts), 5)
	for u in us[1:4] do testing.expect_value(t, u, 0.8)
	testing.expect(t, abs(lefts[2] - (10 + 100.0 / 3)) < 0.5, "three equal tiles")
}

@(test)
test_skin_without_border_tiles_the_image :: proc(t: ^testing.T) {
	c: Canvas
	defer destroy(&c)
	skin(&c, {{0, 0}, {100, 50}}, Skin{image = 1, size = {40, 50}, mode = {.REPEAT, .STRETCH}})
	_, _, batches := mesh(&c)
	testing.expect_value(t, batches[0].vertex_count, 3 * 4)
}

@(test)
test_text_draws_glyphs_on_the_atlas :: proc(t: ^testing.T) {
	f: font.Font
	font.init(&f, TEST_FONT, {})
	defer font.destroy(&f)
	c := Canvas{dpi = 2}
	defer destroy(&c)
	w := text(&c, &f, "Hi", {10, 10}, 16, WHITE)
	_, _, batches := mesh(&c)
	testing.expect_value(t, len(batches), 1)
	testing.expect_value(t, batches[0].texture, FONT_TEXTURE)
	testing.expect_value(t, batches[0].vertex_count, 2 * 4)
	testing.expect(t, abs(w - font.measure(&f, "Hi", 32) / 2) < 1e-4, "width in window units")
}
