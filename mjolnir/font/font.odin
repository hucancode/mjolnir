// Text metrics and glyph quads over one TTF/OTF font, rasterized on demand
// into an R8 atlas. Layer 1: no GPU, no other module. A UI measures with it;
// a renderer draws its glyphs and uploads its atlas.
package font

import "core:log"
import "core:slice"
import fs "vendor:fontstash"

// The fontstash context of one font. Use it by pointer only.
Font :: fs.FontContext

// One glyph quad: corners in pixels, uvs in atlas texels so they stay valid
// when the atlas grows.
Glyph :: struct {
  p0, p1:   [2]f32,
  uv0, uv1: [2]f32,
}

// Glyph sizes rasterized at init so the first atlas upload covers typical
// text without growing the atlas; other sizes rasterize on first use.
DEFAULT_PREWARM_SIZES :: []f32{14, 16, 20, 24}

@(private = "file")
PREWARM_TEXT :: " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

// `font_data` is a TTF/OTF file in memory; it is copied. Paired with destroy.
init :: proc(f: ^Font, font_data: []u8, prewarm_sizes := DEFAULT_PREWARM_SIZES) -> bool {
  fs.Init(f, 512, 512, .TOPLEFT)
  if fs.AddFontMem(f, "default", slice.clone(font_data), true) == fs.INVALID {
    log.errorf("Failed to load font (%d bytes)", len(font_data))
    fs.Destroy(f)
    return false
  }
  for size in prewarm_sizes {
    out: [dynamic]Glyph
    glyphs(f, PREWARM_TEXT, {}, size, &out)
    delete(out)
  }
  return true
}

destroy :: proc(f: ^Font) {
  fs.Destroy(f)
}

// Text state of one line at `size` pixels, positioned by its top-left.
@(private = "file")
set_line :: proc(f: ^Font, size: f32) {
  fs.ClearState(f)
  fs.SetSize(f, size)
  fs.SetAlignVertical(f, .TOP)
}

// Width of `text` on one line at `size` pixels.
measure :: proc(f: ^Font, text: string, size: f32) -> f32 {
  set_line(f, size)
  return fs.TextBounds(f, text)
}

// Distance between two lines at `size` pixels.
line_height :: proc(f: ^Font, size: f32) -> f32 {
  set_line(f, size)
  _, _, h := fs.VerticalMetrics(f)
  return h
}

// Append the glyphs of `text` on one line whose top-left is `origin`.
glyphs :: proc(f: ^Font, text: string, origin: [2]f32, size: f32, out: ^[dynamic]Glyph) {
  set_line(f, size)
  iter := fs.TextIterInit(f, origin.x, origin.y, text)
  q: fs.Quad
  for fs.TextIterNext(f, &iter, &q) {
    // after the glyph rasterized: it may have grown the atlas, which keeps
    // every glyph's texels
    texels := [2]f32{f32(f.width), f32(f.height)}
    append(out, Glyph{{q.x0, q.y0}, {q.x1, q.y1}, [2]f32{q.s0, q.t0} * texels, [2]f32{q.s1, q.t1} * texels})
  }
}

// The R8 atlas pixels (size.x by size.y); changed when glyphs were
// rasterized or the atlas grew since the previous call.
atlas :: proc(f: ^Font) -> (pixels: []u8, size: [2]u32, changed: bool) {
  dirty: [4]f32
  changed = fs.ValidateTexture(f, &dirty)
  return f.textureData, {u32(f.width), u32(f.height)}, changed
}
