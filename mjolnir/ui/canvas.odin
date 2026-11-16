package ui

import "../font"
import "../geometry"
import "core:math"

// Vertex2D is one canvas vertex: position in window units, uv, color.
Vertex2D :: geometry.Vertex2D

// FONT_TEXTURE stands for the font's glyph atlas in Batch.texture: the renderer's copy of it,
// sampled with uvs in atlas texels (font.Glyph's), which hold as the atlas grows.
FONT_TEXTURE :: max(u32)

// Batch is a run of a canvas drawn with one texture, sampling, clip and z; its indices count
// from its first vertex.
Batch :: struct {
  first_vertex, vertex_count: u32,
  first_index, index_count:   u32,
  // a texture the renderer knows, 0 for none (white), or FONT_TEXTURE
  texture:                    u32,
  clip:                       Rect,
  z:                          i32,
  // sampled bilinearly, else nearest
  smooth:                     bool,
}

// Canvas is a 2D draw list in window units (render.window_size), refilled each frame: reset it,
// draw, then hand mesh to a renderer. Free it with destroy.
Canvas :: struct {
  // framebuffer pixels per window unit (the DPI scale): edges snap to them and text rasterizes
  // at them; 0 counts as 1
  dpi:     f32,
  // what the next draws take: a renderer draws batches by z, ascending, ties in the order drawn
  z:       i32,
  // where the next draws show, a zero clip being the whole window
  clip:    Rect,
  using _: Canvas_State,
}

@(private)
Canvas_State :: struct {
  vertices: [dynamic]Vertex2D,
  indices:  [dynamic]u32,
  batches:  [dynamic]Batch,
}

@(private)
WHITE :: [4]u8{255, 255, 255, 255}

@(private)
FULL_UV :: [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}

// reset empties the canvas for the next frame's draws; z and clip go back to zero.
reset :: proc(self: ^Canvas) {
  clear(&self.vertices)
  clear(&self.indices)
  clear(&self.batches)
  self.z, self.clip = 0, {}
}

// destroy frees what the canvas holds.
destroy :: proc(self: ^Canvas) {
  delete(self.vertices)
  delete(self.indices)
  delete(self.batches)
  self^ = {}
}

// mesh returns what was drawn since the last reset: draw each batch's slice of the vertices and
// indices, by z, with its texture inside its clip.
mesh :: proc(self: ^Canvas) -> (vertices: []Vertex2D, indices: []u32, batches: []Batch) {
  return self.vertices[:], self.indices[:], self.batches[:]
}

// rect fills `r` with `color`, or with `texture` tinted by it: `uv` are the texture coordinates
// of its top-left, top-right, bottom-right and bottom-left corners (a sheet's cell), zero
// showing all of it.
rect :: proc(self: ^Canvas, r: Rect, color: [4]u8, texture: u32 = 0, uv: [4][2]f32 = {}, smooth := false) {
  p0, p1 := snap(self, r.pos), snap(self, r.pos + r.size)
  quad(self, p0, p1, uv if uv != {} else FULL_UV, color, texture, smooth)
}

// border draws a frame `width` thick inside `r`, at least one framebuffer pixel.
border :: proc(self: ^Canvas, r: Rect, width: f32, color: [4]u8) {
  dpi := dpi_of(self)
  p0, p1 := snap(self, r.pos), snap(self, r.pos + r.size)
  b := max(math.round(width * dpi), 1) / dpi
  quad(self, p0, {p1.x, p0.y + b}, FULL_UV, color, 0)
  quad(self, {p0.x, p1.y - b}, p1, FULL_UV, color, 0)
  quad(self, {p0.x, p0.y + b}, {p0.x + b, p1.y - b}, FULL_UV, color, 0)
  quad(self, {p1.x - b, p0.y + b}, {p1.x, p1.y - b}, FULL_UV, color, 0)
}

// text draws one line of `s` at `size` window units, the point at `pivot` (0..1 of its width and
// line height) on `pos`: {} puts its top-left there, {0.5, 0.5} centres it. Glyphs rasterize at
// whole framebuffer pixel sizes. It returns the line's width.
text :: proc(self: ^Canvas, f: ^font.Font, s: string, pos: [2]f32, size: f32, color := WHITE, pivot: [2]f32 = {}) -> f32 {
  if f == nil || len(s) == 0 do return 0
  dpi := dpi_of(self)
  px := max(math.round(size * dpi), 1)
  width := font.measure(f, s, px)
  origin := pos * dpi
  if pivot != {} do origin -= pivot * [2]f32{width, font.line_height(f, px)}
  glyphs := make([dynamic]font.Glyph, context.temp_allocator)
  font.glyphs(f, s, {math.round(origin.x), math.round(origin.y)}, px, &glyphs)
  for g in glyphs {
    quad(self, g.p0 / dpi, g.p1 / dpi, {g.uv0, {g.uv1.x, g.uv0.y}, g.uv1, {g.uv0.x, g.uv1.y}}, color, FONT_TEXTURE)
  }
  return width / dpi
}

// triangles draws an indexed triangle mesh as given: positions in window units, uvs in the
// texture's 0..1 (in atlas texels with FONT_TEXTURE), indices counting from its first vertex.
triangles :: proc(self: ^Canvas, vertices: []Vertex2D, indices: []u32, texture: u32 = 0, smooth := false) {
  b := batch(self, texture, smooth)
  base := b.vertex_count
  append(&self.vertices, ..vertices)
  for i in indices do append(&self.indices, base + i)
  b.vertex_count += u32(len(vertices))
  b.index_count += u32(len(indices))
}

// The canvas's DPI, 0 counting as 1.
@(private)
dpi_of :: proc(self: ^Canvas) -> f32 {
  return self.dpi if self.dpi > 0 else 1
}

// A point on the nearest framebuffer pixel.
@(private)
snap :: proc(self: ^Canvas, p: [2]f32) -> [2]f32 {
  dpi := dpi_of(self)
  return {math.round(p.x * dpi), math.round(p.y * dpi)} / dpi
}

// The last batch when it draws like this, else a new one.
@(private)
batch :: proc(self: ^Canvas, texture: u32, smooth: bool) -> ^Batch {
  n := len(self.batches)
  if n > 0 {
    last := &self.batches[n - 1]
    if last.texture == texture && last.smooth == smooth && last.clip == self.clip && last.z == self.z do return last
  }
  append(&self.batches, Batch{first_vertex = u32(len(self.vertices)), first_index = u32(len(self.indices)), texture = texture, clip = self.clip, z = self.z, smooth = smooth})
  return &self.batches[n]
}

// A quad from p0 to p1 whose corners show `uv`.
@(private)
quad :: proc(self: ^Canvas, p0, p1: [2]f32, uv: [4][2]f32, color: [4]u8, texture: u32, smooth := false) {
  b := batch(self, texture, smooth)
  base := b.vertex_count
  append(&self.vertices, Vertex2D{p0, uv[0], color}, Vertex2D{{p1.x, p0.y}, uv[1], color}, Vertex2D{p1, uv[2], color}, Vertex2D{{p0.x, p1.y}, uv[3], color})
  append(&self.indices, base, base + 1, base + 2, base, base + 2, base + 3)
  b.vertex_count += 4
  b.index_count += 6
}
