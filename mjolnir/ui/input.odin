package ui

import "../input"

// pick returns the topmost shown node under `point`, inside its clip, that is interactive
// or sits inside an interactive node; none when there is no such node.
@(private)
pick :: proc(self: ^UI, point: [2]f32) -> NodeHandle {
  #reverse for h in self.draw_order {
    if !contains(self.rects[h.index], point) || !contains(self.clips[h.index], point) do continue
    for a := h; a != {}; {
      n := node(self, a) or_break
      if n.interactive do return h
      a = n.parent
    }
  }
  return {}
}

@(private = "file")
contains :: proc(r: Rect, p: [2]f32) -> bool {
  return p.x >= r.pos.x && p.y >= r.pos.y && p.x <= r.pos.x + r.size.x && p.y <= r.pos.y + r.size.y
}

// update_input runs one input tick against the last layout: hovered is the picked node; a
// press makes it pressed (until every button releases) and focuses its
// nearest focusable node, or clears focus over nothing; releasing over the
// pressed node clicks it. Captures the mouse while a node is hovered or
// pressed and the keyboard while one is focused (see input.State); skipped
// while another consumer holds the mouse.
update_input :: proc(self: ^UI, s: ^input.State) {
  self.clicked = {}
  if s.mouse_captured do return
  self.hovered = pick(self, s.cursor)
  held := false
  for b in input.MouseButton {
    held ||= input.mouse_down(s, b)
    if input.mouse_pressed(s, b) {
      if self.pressed == {} do self.pressed = self.hovered
      self.focused = {}
      for a := self.hovered; a != {}; {
        n := node(self, a) or_break
        if n.focusable {
          self.focused = a
          break
        }
        a = n.parent
      }
    }
    if input.mouse_released(s, b) && within(self, self.hovered, self.pressed) do self.clicked = self.pressed
  }
  if !held do self.pressed = {}
  if _, ok := node(self, self.focused); !ok do self.focused = {}
  if self.hovered != {} || self.pressed != {} do s.mouse_captured = true
  if self.focused != {} do s.keyboard_captured = true
}

// hovered reports whether the cursor is over `handle` or a node inside it.
hovered :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return within(self, self.hovered, handle)
}

// pressed reports whether the node held down is `handle` or inside it.
pressed :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return within(self, self.pressed, handle)
}

// clicked reports whether this tick released a press made on `handle` (or inside it) over the
// same node.
clicked :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return within(self, self.clicked, handle)
}

// focused reports whether `handle` or a node inside it has keyboard focus. Read keys and text
// from input.State while it does.
focused :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return within(self, self.focused, handle)
}
