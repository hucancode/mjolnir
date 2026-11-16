package ui

import "../font"
import "core:math"

@(private = "file")
WHITE :: [4]u8{255, 255, 255, 255}

@(private = "file")
FULL_UV :: [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}

// Tessellates every shown node, back to front, into the mesh in window pixels snapped to the
// framebuffer's (`dpi` of them per window pixel): its fill, its image, its border, its text, each
// color times the node's tint and its ancestors'. Glyphs rasterize at whole framebuffer pixel
// sizes and keep their uvs in atlas texels. A node's look is its style in its interaction.
@(private)
paint :: proc(self: ^UI, f: ^font.Font, dpi: f32) {
  clear(&self.vertices)
  clear(&self.indices)
  clear(&self.batches)
  resize(&self.interaction, len(self.rects))
  tints := make([][4]u8, len(self.rects), context.temp_allocator)
  for i in self.topo {
    nd := &self.nodes[i]
    state := Interaction.NORMAL
    tint := nd.tint if nd.tint != {} else WHITE
    if p := parent_of(self, i); p >= 0 {
      state = self.interaction[p]
      tint = multiply(tints[p], tint)
    }
    if nd.interactive {
      h := handle_of(self, i)
      state = .PRESSED if within(self, self.pressed, h) else .HOVERED if within(self, self.hovered, h) else .NORMAL
    }
    if nd.active && !(nd.interactive && state == .PRESSED) do state = .ACTIVE
    self.interaction[i] = state
    tints[i] = tint
  }
  snap :: proc(p: [2]f32, dpi: f32) -> [2]f32 {
    return {math.round(p.x * dpi), math.round(p.y * dpi)} / dpi
  }
  glyphs := make([dynamic]font.Glyph, context.temp_allocator)
  for h in self.draw_order {
    i := h.index
    nd := &self.nodes[i]
    clip := self.clips[i]
    r := self.rects[i]
    if clip.size.x <= 0 || clip.size.y <= 0 || !overlaps(r, clip) do continue
    st := self.styles[nd.style][self.interaction[i]] if int(nd.style) < len(self.styles) else {}
    tint := tints[i]
    p0, p1 := snap(r.pos, dpi), snap(r.pos + r.size, dpi)
    if st.fill.a > 0 do quad(self, p0, p1, FULL_UV, multiply(st.fill, tint), 0, clip)
    if color := multiply(st.color, tint); nd.image != 0 && color.a > 0 {
      uv := nd.image_uv if nd.image_uv != {} else FULL_UV
      if nd.slice.border == {} do quad(self, p0, p1, uv, color, nd.image, clip, nd.smooth)
      else do nine(self, p0, p1, uv, nd.slice, color, nd.image, clip, nd.smooth, dpi)
    }
    if st.border > 0 && st.border_color.a > 0 {
      b := max(math.round(st.border * self.frame.scale * dpi), 1) / dpi
      c := multiply(st.border_color, tint)
      quad(self, p0, {p1.x, p0.y + b}, FULL_UV, c, 0, clip)
      quad(self, {p0.x, p1.y - b}, p1, FULL_UV, c, 0, clip)
      quad(self, {p0.x, p0.y + b}, {p0.x + b, p1.y - b}, FULL_UV, c, 0, clip)
      quad(self, {p1.x - b, p0.y + b}, {p1.x, p1.y - b}, FULL_UV, c, 0, clip)
    }
    color := multiply(st.color, tint)
    if f == nil || color.a == 0 do continue
    for line in lines(self, h) {
      clear(&glyphs)
      // whole pixels: a size rasterizes its glyphs once, however the window scales
      size := max(math.round(line.size * dpi), 1)
      origin := [2]f32{math.round(line.pos.x * dpi), math.round(line.pos.y * dpi)}
      text := nd.text[line.start:line.end]
      font.glyphs(f, text, origin, size, &glyphs)
      if line.ellipsis do font.glyphs(f, ELLIPSIS, origin + {font.measure(f, text, size), 0}, size, &glyphs)
      for g in glyphs {
        quad(self, g.p0 / dpi, g.p1 / dpi, {g.uv0, {g.uv1.x, g.uv0.y}, g.uv1, {g.uv0.x, g.uv1.y}}, color, FONT_TEXTURE, clip)
      }
    }
  }
}

// a times b, per channel, 255 being 1.
@(private = "file")
multiply :: proc(a, b: [4]u8) -> [4]u8 {
  return {u8(u32(a.r) * u32(b.r) / 255), u8(u32(a.g) * u32(b.g) / 255), u8(u32(a.b) * u32(b.b) / 255), u8(u32(a.a) * u32(b.a) / 255)}
}

// The uv at (s, t), 0..1 across and down, of the quad whose corners show `uv`.
@(private = "file")
uv_at :: proc(uv: [4][2]f32, s, t: f32) -> [2]f32 {
  top := uv[0] + (uv[1] - uv[0]) * s
  bottom := uv[3] + (uv[2] - uv[3]) * s
  return top + (bottom - top) * t
}

// The image cut in nine from p0 to p1: borders in reference units, the corners' cells unscaled.
@(private = "file")
nine :: proc(self: ^UI, p0, p1: [2]f32, uv: [4][2]f32, slice: Slice, color: [4]u8, texture: u32, clip: Rect, smooth: bool, dpi: f32) {
  border := slice.border * self.frame.scale
  for &b in border do b = math.round(b * dpi) / dpi
  // borders wider than the node shrink to meet
  size := p1 - p0
  for axis in 0 ..< 2 {
    sum := border[axis] + border[axis + 2]
    if sum > size[axis] && sum > 0 {
      border[axis] *= size[axis] / sum
      border[axis + 2] *= size[axis] / sum
    }
  }
  xs := [4]f32{p0.x, p0.x + border[0], p1.x - border[2], p1.x}
  ys := [4]f32{p0.y, p0.y + border[1], p1.y - border[3], p1.y}
  ss := [4]f32{0, slice.uv[0], 1 - slice.uv[2], 1}
  ts := [4]f32{0, slice.uv[1], 1 - slice.uv[3], 1}
  for row in 0 ..< 3 do for col in 0 ..< 3 {
    if xs[col + 1] <= xs[col] || ys[row + 1] <= ys[row] do continue
    cell := [4][2]f32 {
      uv_at(uv, ss[col], ts[row]),
      uv_at(uv, ss[col + 1], ts[row]),
      uv_at(uv, ss[col + 1], ts[row + 1]),
      uv_at(uv, ss[col], ts[row + 1]),
    }
    quad(self, {xs[col], ys[row]}, {xs[col + 1], ys[row + 1]}, cell, color, texture, clip, smooth)
  }
}

// Appends a quad to the last batch, or to a new one when the texture, sampling or clip differ.
@(private = "file")
quad :: proc(self: ^UI, p0, p1: [2]f32, uv: [4][2]f32, color: [4]u8, texture: u32, clip: Rect, smooth := false) {
  n := len(self.batches)
  if n == 0 || self.batches[n - 1].texture != texture || self.batches[n - 1].clip != clip || self.batches[n - 1].smooth != smooth {
    append(&self.batches, Batch{first_vertex = u32(len(self.vertices)), first_index = u32(len(self.indices)), texture = texture, clip = clip, smooth = smooth})
  }
  b := &self.batches[len(self.batches) - 1]
  base := b.vertex_count
  append(&self.vertices, {p0, uv[0], color}, {{p1.x, p0.y}, uv[1], color}, {p1, uv[2], color}, {{p0.x, p1.y}, uv[3], color})
  append(&self.indices, base, base + 1, base + 2, base, base + 2, base + 3)
  b.vertex_count += 4
  b.index_count += 6
}

@(private = "file")
overlaps :: proc(a, b: Rect) -> bool {
  return a.pos.x < b.pos.x + b.size.x && b.pos.x < a.pos.x + a.size.x && a.pos.y < b.pos.y + b.size.y && b.pos.y < a.pos.y + a.size.y
}
