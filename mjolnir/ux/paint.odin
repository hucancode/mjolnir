package ux

import "../font"
import "../ui"
import "core:math"

@(private = "file")
WHITE :: [4]u8{255, 255, 255, 255}

// Paints every shown node, back to front, into the canvas in window pixels snapped to the
// framebuffer's (`dpi` of them per window pixel): its fill, its skin, its image, its border, its
// text (with the caret and selection while it is edited), each color times the node's tint and its
// ancestors'. A node's look is its style in its interaction. Nodes draw at z 0, and two higher
// after each `overlay` node, leaving the z between for the application (layer).
@(private)
paint :: proc(self: ^UI, f: ^font.Font, dpi: f32) {
  c := &self.canvas
  ui.reset(c)
  c.dpi = dpi
  resize(&self.interaction, len(self.rects))
  resize(&self.layers, len(self.rects))
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
  for h in self.draw_order {
    i := h.index
    nd := &self.nodes[i]
    self.layers[i] = c.z + 1
    clip := self.clips[i]
    r := self.rects[i]
    defer if nd.overlay do c.z += 2
    if clip.size.x <= 0 || clip.size.y <= 0 || !overlaps(r, clip) do continue
    c.clip = clip
    st := self.styles[nd.style][self.interaction[i]] if int(nd.style) < len(self.styles) else {}
    tint := tints[i]
    if st.fill.a > 0 do ui.rect(c, r, multiply(st.fill, tint))
    if st.skin.image != 0 do ui.skin(c, r, st.skin, tint, self.frame.scale)
    color := multiply(st.color, tint)
    if nd.image != 0 && color.a > 0 do ui.rect(c, r, color, nd.image, nd.image_uv, nd.smooth)
    if st.border > 0 && st.border_color.a > 0 do ui.border(c, r, st.border * self.frame.scale, multiply(st.border_color, tint))
    if f == nil || color.a == 0 do continue
    if nd.clip do c.clip = ui.intersect(clip, r)
    if h == self.focused && nd.editable do paint_edit(self, h, f, color)
    for line in lines(self, h) {
      text := nd.text[line.start:line.end]
      w := ui.text(c, f, text, line.pos, line.size, color)
      if line.ellipsis do ui.text(c, f, ELLIPSIS, line.pos + {w, 0}, line.size, color)
    }
  }
}

// The selection under the focused text and the caret, in its color.
@(private = "file")
paint_edit :: proc(self: ^UI, h: NodeHandle, f: ^font.Font, color: [4]u8) {
  ls := lines(self, h)
  if len(ls) == 0 do return
  line := ls[0]
  c := &self.canvas
  height := font.line_height(f, line.size)
  lo, hi := min(self.caret, self.mark), max(self.caret, self.mark)
  if lo != hi {
    x0, x1 := caret_x(self, h, f, lo), caret_x(self, h, f, hi)
    ui.rect(c, {{x0, line.pos.y}, {x1 - x0, height}}, {color.r, color.g, color.b, color.a / 3})
  }
  x := caret_x(self, h, f, self.caret)
  ui.rect(c, {{x, line.pos.y}, {max(self.frame.scale, 1 / max(c.dpi, 1)), height}}, color)
}

// The window x of the caret before text[at] on a node's first line, measured as it is drawn.
@(private)
caret_x :: proc(self: ^UI, h: NodeHandle, f: ^font.Font, at: int) -> f32 {
  ls := lines(self, h)
  if len(ls) == 0 do return 0
  line := ls[0]
  text := self.nodes[h.index].text
  dpi := self.dpi if self.dpi > 0 else 1
  px := max(math.round(line.size * dpi), 1)
  return line.pos.x + font.measure(f, text[line.start:clamp(at, line.start, line.end)], px) / dpi
}

// a times b, per channel, 255 being 1.
@(private = "file")
multiply :: proc(a, b: [4]u8) -> [4]u8 {
  return {u8(u32(a.r) * u32(b.r) / 255), u8(u32(a.g) * u32(b.g) / 255), u8(u32(a.b) * u32(b.b) / 255), u8(u32(a.a) * u32(b.a) / 255)}
}

@(private = "file")
overlaps :: proc(a, b: Rect) -> bool {
  return a.pos.x < b.pos.x + b.size.x && b.pos.x < a.pos.x + a.size.x && a.pos.y < b.pos.y + b.size.y && b.pos.y < a.pos.y + a.size.y
}
