#+private file
package font

import "core:testing"

TEST_FONT :: #load("../../assets/Outfit-Regular.ttf")

@(test)
test_measure_grows_with_text_and_size :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, init(&f, TEST_FONT, {}))
	defer destroy(&f)
	testing.expect(t, measure(&f, "abc", 16) < measure(&f, "abcdef", 16), "longer text is wider")
	testing.expect(t, measure(&f, "abc", 16) < measure(&f, "abc", 32), "larger text is wider")
	testing.expect(t, line_height(&f, 16) < line_height(&f, 32), "larger text is taller")
}

@(test)
test_glyphs_follow_origin_and_atlas :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, init(&f, TEST_FONT, {}))
	defer destroy(&f)
	out: [dynamic]Glyph
	defer delete(out)
	glyphs(&f, "Hi", {100, 50}, 20, &out)
	testing.expect_value(t, len(out), 2)
	testing.expect(t, out[0].p0.x >= 100 && out[0].p0.y >= 50, "glyphs start at the origin")
	pixels, size, changed := atlas(&f)
	testing.expect(t, changed && len(pixels) == int(size.x * size.y), "rasterized glyphs change the atlas")
	for g in out do testing.expect(t, g.uv1.x <= f32(size.x) && g.uv1.y <= f32(size.y), "uvs in texels")
	_, _, again := atlas(&f)
	testing.expect(t, !again, "no change without new glyphs")
}
