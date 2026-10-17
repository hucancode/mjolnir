package font

import "core:log"
import "core:slice"
import fs "vendor:fontstash"

// Font is one loaded font and its glyph atlas. Use it by pointer only.
Font :: struct {
  using _: Font_State,
}

@(private)
Font_State :: struct {
  ctx: fs.FontContext,
}

// Glyph is one glyph quad: corners in pixels, uvs in atlas texels so they stay valid
// when the atlas grows.
Glyph :: struct {
  p0, p1:   [2]f32,
  uv0, uv1: [2]f32,
}

// DEFAULT_PREWARM_SIZES are the glyph sizes rasterized at init; others rasterize on first use.
DEFAULT_PREWARM_SIZES :: []f32{14, 16, 20, 24}

@(private = "file")
PREWARM_TEXT :: " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

// init loads a font; `font_data` is a TTF/OTF file in memory; it is copied. Paired with destroy.
init :: proc(self: ^Font, font_data: []u8, prewarm_sizes := DEFAULT_PREWARM_SIZES) -> bool {
  fs.Init(&self.ctx, 512, 512, .TOPLEFT)
  if fs.AddFontMem(&self.ctx, "default", slice.clone(font_data), true) == fs.INVALID {
    log.errorf("Failed to load font (%d bytes)", len(font_data))
    fs.Destroy(&self.ctx)
    return false
  }
  for size in prewarm_sizes {
    out: [dynamic]Glyph
    glyphs(self, PREWARM_TEXT, {}, size, &out)
    delete(out)
  }
  return true
}

// destroy frees the font and its atlas.
destroy :: proc(self: ^Font) {
  fs.Destroy(&self.ctx)
}

// Text state of one line at `size` pixels, positioned by its top-left.
@(private = "file")
set_line :: proc(self: ^Font, size: f32) {
  fs.ClearState(&self.ctx)
  fs.SetSize(&self.ctx, size)
  fs.SetAlignVertical(&self.ctx, .TOP)
}

// measure returns the width of `text` on one line at `size` pixels.
measure :: proc(self: ^Font, text: string, size: f32) -> f32 {
  set_line(self, size)
  return fs.TextBounds(&self.ctx, text)
}

// line_height returns the distance between two lines at `size` pixels.
line_height :: proc(self: ^Font, size: f32) -> f32 {
  set_line(self, size)
  _, _, h := fs.VerticalMetrics(&self.ctx)
  return h
}

// glyphs appends the glyphs of `text` on one line whose top-left is `origin`.
glyphs :: proc(self: ^Font, text: string, origin: [2]f32, size: f32, out: ^[dynamic]Glyph) {
  set_line(self, size)
  iter := fs.TextIterInit(&self.ctx, origin.x, origin.y, text)
  q: fs.Quad
  for fs.TextIterNext(&self.ctx, &iter, &q) {
    // after the glyph rasterized: it may have grown the atlas, which keeps
    // every glyph's texels
    texels := [2]f32{f32(self.ctx.width), f32(self.ctx.height)}
    append(out, Glyph{{q.x0, q.y0}, {q.x1, q.y1}, [2]f32{q.s0, q.t0} * texels, [2]f32{q.s1, q.t1} * texels})
  }
}

// atlas returns the R8 atlas pixels (size.x by size.y); changed when glyphs were
// rasterized or the atlas grew since the previous call.
atlas :: proc(self: ^Font) -> (pixels: []u8, size: [2]u32, changed: bool) {
  dirty: [4]f32
  changed = fs.ValidateTexture(&self.ctx, &dirty)
  return self.ctx.textureData, {u32(self.ctx.width), u32(self.ctx.height)}, changed
}
