#+build !js
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
	before := f.version
	pixels, size, version := atlas(&f)
	testing.expect(t, version != before && len(pixels) == int(size.x * size.y), "rasterized glyphs change the atlas")
	for g in out do testing.expect(t, g.uv1.x <= f32(size.x) && g.uv1.y <= f32(size.y), "uvs in texels")
	_, _, again := atlas(&f)
	testing.expect(t, again == version, "no change without new glyphs")
}

// Two fonts never share an atlas version, so a renderer holding one font's atlas re-uploads for
// the other, and reading one font's atlas does not hide another's changes.
@(test)
test_atlas_versions_differ_across_fonts :: proc(t: ^testing.T) {
	a, b: Font
	testing.expect(t, init(&a, TEST_FONT, {}))
	defer destroy(&a)
	testing.expect(t, init(&b, TEST_FONT, {}))
	defer destroy(&b)
	_, _, va := atlas(&a)
	_, _, vb := atlas(&b)
	testing.expect(t, va != vb, "two fonts have different versions")
	_, _, va2 := atlas(&a)
	testing.expect(t, va2 == va, "an unchanged font keeps its version")
}
