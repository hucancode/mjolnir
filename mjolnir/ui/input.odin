package ui

import cont "../containers"
import "../input"

// The topmost shown node under `point`, inside its clip, that is interactive
// or sits inside an interactive node; none when there is no such node.
pick :: proc(self: ^UI, point: [2]f32) -> NodeHandle {
  #reverse for h in self.draw_order {
    if !contains(self.rects[h.index], point) || !contains(self.clips[h.index], point) do continue
    for a := h; a != {}; {
      n := cont.get(self.nodes, a) or_break
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

// Run one input tick against the last layout: hovered is the picked node; a
// press makes it pressed (until every button releases) and focuses its
// nearest focusable node, or clears focus over nothing; releasing over the
// pressed node clicks it. Captures the mouse while a node is hovered or
// pressed and the keyboard while one is focused (see input.State); skipped
// while another consumer holds the mouse.
update_input :: proc(self: ^UI, s: ^input.State) {
  self.clicked = {}
  if s.mouse_captured do return
  self.hovered = pick(self, s.cursor)
  for b in input.MouseButton {
    if input.mouse_pressed(s, b) {
      if self.pressed == {} do self.pressed = self.hovered
      self.focused = {}
      for a := self.hovered; a != {}; {
        n := cont.get(self.nodes, a) or_break
        if n.focusable {
          self.focused = a
          break
        }
        a = n.parent
      }
    }
    if input.mouse_released(s, b) && within(self, self.hovered, self.pressed) do self.clicked = self.pressed
  }
  if s.buttons == {} do self.pressed = {}
  if _, ok := cont.get(self.nodes, self.focused); !ok do self.focused = {}
  if self.hovered != {} || self.pressed != {} do s.mouse_captured = true
  if self.focused != {} do s.keyboard_captured = true
}

// Whether the cursor is over `h` or a node inside it.
hovered :: proc(self: ^UI, h: NodeHandle) -> bool {
  return within(self, self.hovered, h)
}

// Whether the node held down is `h` or inside it.
pressed :: proc(self: ^UI, h: NodeHandle) -> bool {
  return within(self, self.pressed, h)
}

// Whether this tick released a press made on `h` (or inside it) over the
// same node.
clicked :: proc(self: ^UI, h: NodeHandle) -> bool {
  return within(self, self.clicked, h)
}

// Whether `h` or a node inside it has keyboard focus. Read keys and text
// from input.State while it does.
focused :: proc(self: ^UI, h: NodeHandle) -> bool {
  return within(self, self.focused, h)
}
