package ui

import "../font"
import "core:math"

// Tessellates every shown node, back to front, into the mesh in framebuffer pixels: its fill,
// its image, its border, its text; then divides glyph uvs by the atlas size,
// which only grows while glyphs rasterize. A node's look is its style in its interaction.
@(private)
paint :: proc(self: ^UI, f: ^font.Font, dpi: f32) {
  clear(&self.vertices)
  clear(&self.indices)
  clear(&self.batches)
  resize(&self.interaction, len(self.rects))
  for i in self.topo {
    nd := &self.nodes[i]
    state := Interaction.NORMAL
    if p := parent_of(self, i); p >= 0 do state = self.interaction[p]
    if nd.interactive {
      h := handle_of(self, i)
      state = .PRESSED if within(self, self.pressed, h) else .HOVERED if within(self, self.hovered, h) else .NORMAL
    }
    if nd.active && !(nd.interactive && state == .PRESSED) do state = .ACTIVE
    self.interaction[i] = state
  }
  glyphs := make([dynamic]font.Glyph, context.temp_allocator)
  for h in self.draw_order {
    i := h.index
    nd := &self.nodes[i]
    clip := Rect{self.clips[i].pos * dpi, self.clips[i].size * dpi}
    r := self.rects[i]
    if clip.size.x <= 0 || clip.size.y <= 0 || !overlaps(Rect{r.pos * dpi, r.size * dpi}, clip) do continue
    st := self.styles[nd.style][self.interaction[i]] if int(nd.style) < len(self.styles) else {}
    p0 := [2]f32{math.round(r.pos.x * dpi), math.round(r.pos.y * dpi)}
    p1 := [2]f32{math.round((r.pos.x + r.size.x) * dpi), math.round((r.pos.y + r.size.y) * dpi)}
    if st.fill.a > 0 do quad(self, p0, p1, {}, {1, 1}, st.fill, 0, clip)
    if nd.image != 0 && st.color.a > 0 {
      region := nd.image_rect
      if region.size == {} do region.size = {1, 1}
      quad(self, p0, p1, region.pos, region.pos + region.size, st.color, nd.image, clip)
    }
    if st.border > 0 && st.border_color.a > 0 {
      b := max(math.round(st.border * self.frame.scale * dpi), 1)
      c := st.border_color
      quad(self, p0, {p1.x, p0.y + b}, {}, {1, 1}, c, 0, clip)
      quad(self, {p0.x, p1.y - b}, p1, {}, {1, 1}, c, 0, clip)
      quad(self, {p0.x, p0.y + b}, {p0.x + b, p1.y - b}, {}, {1, 1}, c, 0, clip)
      quad(self, {p1.x - b, p0.y + b}, {p1.x, p1.y - b}, {}, {1, 1}, c, 0, clip)
    }
    if f == nil || st.color.a == 0 do continue
    for line in lines(self, h) {
      clear(&glyphs)
      origin := [2]f32{math.round(line.pos.x * dpi), math.round(line.pos.y * dpi)}
      font.glyphs(f, nd.text[line.start:line.end], origin, line.size * dpi, &glyphs)
      for g in glyphs do quad(self, g.p0, g.p1, g.uv0, g.uv1, st.color, FONT_TEXTURE, clip)
    }
  }
  if f == nil do return
  size := font.atlas_size(f)
  texels := [2]f32{f32(size.x), f32(size.y)}
  for b in self.batches do if b.texture == FONT_TEXTURE {
    for &v in self.vertices[b.first_vertex:][:b.vertex_count] do v.uv /= texels
  }
}

// Appends a quad to the last batch, or to a new one when the texture or clip differ.
@(private = "file")
quad :: proc(self: ^UI, p0, p1, uv0, uv1: [2]f32, color: [4]u8, texture: u32, clip: Rect) {
  n := len(self.batches)
  if n == 0 || self.batches[n - 1].texture != texture || self.batches[n - 1].clip != clip {
    append(&self.batches, Batch{first_vertex = u32(len(self.vertices)), first_index = u32(len(self.indices)), texture = texture, clip = clip})
  }
  b := &self.batches[len(self.batches) - 1]
  base := b.vertex_count
  append(
    &self.vertices,
    {p0, uv0, color},
    {{p1.x, p0.y}, {uv1.x, uv0.y}, color},
    {p1, uv1, color},
    {{p0.x, p1.y}, {uv0.x, uv1.y}, color},
  )
  append(&self.indices, base, base + 1, base + 2, base, base + 2, base + 3)
  b.vertex_count += 4
  b.index_count += 6
}

@(private = "file")
overlaps :: proc(a, b: Rect) -> bool {
  return a.pos.x < b.pos.x + b.size.x && b.pos.x < a.pos.x + a.size.x && a.pos.y < b.pos.y + b.size.y && b.pos.y < a.pos.y + a.size.y
}
