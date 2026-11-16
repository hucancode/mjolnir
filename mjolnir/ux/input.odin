package ux

import "../input"
import "../ui"
import "core:strings"
import "core:unicode/utf8"

// pick returns the topmost shown node under `point`, inside its clip, that is interactive
// or sits inside an interactive node; none when there is no such node.
@(private)
pick :: proc(self: ^UI, point: [2]f32) -> NodeHandle {
  #reverse for h in self.draw_order {
    if !ui.contains(self.rects[h.index], point) || !ui.contains(self.clips[h.index], point) do continue
    for a := h; a != {}; {
      n := node(self, a) or_break
      if n.interactive do return h
      a = n.parent
    }
  }
  return {}
}

// The nearest of `h` and its ancestors `which` accepts; none when no node does.
@(private = "file")
nearest :: proc(self: ^UI, h: NodeHandle, which: proc(n: ^Node) -> bool) -> NodeHandle {
  for a := h; a != {}; {
    n := node(self, a) or_break
    if which(n) do return a
    a = n.parent
  }
  return {}
}

// update_input runs one input tick against the last layout. The picked node is hovered; a press
// makes it pressed (until every button releases), focuses its nearest focusable or editable node
// (or clears focus over nothing), raises its `front` ancestors and starts its nearest `drags`;
// releasing over the pressed node clicks it; a left click flips its nearest `toggle` node and
// hides the `hides` target. While held, a drag moves its target by mouse_delta. The wheel scrolls the
// nearest clipping node under the cursor that overflows. A focused editable node takes the typed
// text and Backspace, Delete, Left, Right, Home, End (Shift selects), Ctrl or Cmd with A, C, X
// and V (pasting `clipboard`; copied returns what to put on the clipboard), Enter (submitted) and
// Escape (unfocus). Captures the mouse while a node is hovered or pressed and the keyboard while
// one is focused (see input.State); the mouse part is skipped while another consumer holds it.
update_input :: proc(self: ^UI, s: ^input.State, clipboard := "") {
  self.clicked, self.changed, self.submitted, self.dropped = {}, {}, {}, {}
  delete(self.copied)
  self.copied = ""
  if !s.mouse_captured do pointer(self, s)
  if _, ok := node(self, self.focused); !ok do self.focused = {}
  if self.focused != {} {
    s.keyboard_captured = true
    if n := node(self, self.focused); n.editable do edit(self, s, n, clipboard)
  }
}

// The mouse part of update_input.
@(private = "file")
pointer :: proc(self: ^UI, s: ^input.State) {
  self.hovered = pick(self, s.cursor)
  self.cursor = s.cursor
  // a drag started on an earlier tick follows the mouse
  if self.dragging != {} && input.mouse_down(s, .LEFT) && s.mouse_delta != {} {
    move(self, self.dragging, s.mouse_delta)
    self.changed = self.dragging
  }
  held := false
  for b in input.MouseButton {
    held ||= input.mouse_down(s, b)
    if input.mouse_pressed(s, b) do press(self, s, b)
    if input.mouse_released(s, b) && within(self, self.hovered, self.pressed) do release(self, b)
    if input.mouse_released(s, b) && b == .LEFT && self.pressed != {} do self.dropped = {self.pressed, self.hovered}
  }
  if held && self.text_press == .NONE && self.focused != {} && within(self, self.pressed, self.focused) && s.mouse_delta != {} {
    self.text_press = .EXTEND
  }
  if !held do self.pressed, self.dragging = {}, {}
  if s.scroll != {} do wheel(self, s.scroll)
  if self.hovered != {} || self.pressed != {} do s.mouse_captured = true
}

@(private = "file")
press :: proc(self: ^UI, s: ^input.State, b: input.MouseButton) {
  first := self.pressed == {}
  if first do self.pressed = self.hovered
  was := self.focused
  self.focused = nearest(self, self.hovered, proc(n: ^Node) -> bool {return n.focusable || n.editable})
  if n, ok := node(self, self.focused); ok && n.editable && b == .LEFT {
    shift := input.key_down(s, .LEFT_SHIFT) || input.key_down(s, .RIGHT_SHIFT)
    self.text_press = .EXTEND if shift && was == self.focused else .PLACE
  }
  if !first do return
  for a := self.hovered; a != {}; {
    n := node(self, a) or_break
    if n.front do raise(self, a)
    a = n.parent
  }
  if b == .LEFT {
    from := nearest(self, self.hovered, proc(n: ^Node) -> bool {return n.drags != {}})
    if n, ok := node(self, from); ok do self.dragging = n.drags
  }
}

@(private = "file")
release :: proc(self: ^UI, b: input.MouseButton) {
  self.clicked, self.click_button = self.pressed, b
  if b != .LEFT do return
  if t := nearest(self, self.clicked, proc(n: ^Node) -> bool {return n.toggle}); t != {} {
    n := node(self, t)
    n.active = !n.active
    self.changed = t
  }
  h := nearest(self, self.clicked, proc(n: ^Node) -> bool {return n.hides != {}})
  if n, ok := node(self, h); ok {
    if target, live := node(self, n.hides); live do target.hidden = true
  }
}

// Scrolls the nearest clipping node under the cursor that has room to, three lines a notch.
@(private = "file")
wheel :: proc(self: ^UI, delta: [2]f32) {
  for a := self.hovered; a != {}; {
    n := node(self, a) or_break
    room := max_scroll(self, a)
    if n.clip && (room.x > 0 || room.y > 0) {
      step := self.font_size * 3
      n.scroll = {clamp(n.scroll.x - delta.x * step, 0, room.x), clamp(n.scroll.y - delta.y * step, 0, room.y)}
      return
    }
    a = n.parent
  }
}

// The keyboard part of update_input for the focused editable node.
@(private = "file")
edit :: proc(self: ^UI, s: ^input.State, n: ^Node, clipboard: string) {
  hit :: proc(s: ^input.State, k: input.Key) -> bool {return input.key_pressed(s, k) || input.key_repeated(s, k)}
  shift := input.key_down(s, .LEFT_SHIFT) || input.key_down(s, .RIGHT_SHIFT)
  command := input.key_down(s, .LEFT_CONTROL) || input.key_down(s, .RIGHT_CONTROL) || input.key_down(s, .LEFT_SUPER) || input.key_down(s, .RIGHT_SUPER)
  self.caret, self.mark = clamp(self.caret, 0, len(n.text)), clamp(self.mark, 0, len(n.text))
  lo, hi := min(self.caret, self.mark), max(self.caret, self.mark)
  // moves the caret, the selection's other end too unless shift holds it
  go :: proc(self: ^UI, at: int, shift: bool) {
    self.caret = at
    if !shift do self.mark = at
  }
  if command {
    if input.key_pressed(s, .A) do self.mark, self.caret = 0, len(n.text)
    if (input.key_pressed(s, .C) || input.key_pressed(s, .X)) && lo < hi do self.copied = strings.clone(n.text[lo:hi])
    if input.key_pressed(s, .X) && lo < hi do replace(self, n, "")
    if input.key_pressed(s, .V) && clipboard != "" do replace(self, n, clipboard)
  } else if t := input.text(s); t != "" {
    replace(self, n, t)
  }
  lo, hi = min(self.caret, self.mark), max(self.caret, self.mark)
  if hit(s, .BACKSPACE) {
    if lo == hi do self.mark = before(n.text, self.caret)
    replace(self, n, "")
  } else if hit(s, .DELETE) {
    if lo == hi do self.mark = after(n.text, self.caret)
    replace(self, n, "")
  } else if hit(s, .LEFT) {
    go(self, before(n.text, self.caret) if shift || lo == hi else lo, shift)
  } else if hit(s, .RIGHT) {
    go(self, after(n.text, self.caret) if shift || lo == hi else hi, shift)
  } else if input.key_pressed(s, .HOME) {
    go(self, 0, shift)
  } else if input.key_pressed(s, .END) {
    go(self, len(n.text), shift)
  }
  if input.key_pressed(s, .ENTER) || input.key_pressed(s, .KP_ENTER) do self.submitted = self.focused
  if input.key_pressed(s, .ESCAPE) do self.focused = {}
}

// Replaces the focused text's selection with `with` (newlines dropped: one line), the caret after it.
@(private = "file")
replace :: proc(self: ^UI, n: ^Node, with: string) {
  lo, hi := min(self.caret, self.mark), max(self.caret, self.mark)
  if lo == hi && with == "" do return
  one_line, _ := strings.remove_all(with, "\n", context.temp_allocator)
  one_line, _ = strings.remove_all(one_line, "\r", context.temp_allocator)
  text := strings.concatenate({n.text[:lo], one_line, n.text[hi:]})
  delete(n.text)
  n.text = text
  self.caret, self.mark = lo + len(one_line), lo + len(one_line)
  self.changed = self.focused
  self.dirty = true
}

// The start of the character before `at`, or 0.
@(private = "file")
before :: proc(text: string, at: int) -> int {
  at := at
  for at > 0 {
    at -= 1
    if utf8.rune_start(text[at]) do break
  }
  return at
}

// The end of the character at `at`, or the end of the text.
@(private = "file")
after :: proc(text: string, at: int) -> int {
  if at >= len(text) do return len(text)
  _, size := utf8.decode_rune_in_string(text[at:])
  return at + size
}

// hovered reports whether the cursor is over `handle` or a node inside it.
hovered :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return within(self, self.hovered, handle)
}

// pressed reports whether the node held down is `handle` or inside it.
pressed :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return within(self, self.pressed, handle)
}

// clicked reports whether this tick released a press of `button` made on `handle` (or inside it)
// over the same node.
clicked :: proc(self: ^UI, handle: NodeHandle, button := input.MouseButton.LEFT) -> bool {
  return self.click_button == button && within(self, self.clicked, handle)
}

// dropped reports whether this tick released a left press made inside `from` over `to` (or
// inside it), elsewhere than `from`: an item dragged from one slot onto another.
dropped :: proc(self: ^UI, from, to: NodeHandle) -> bool {
  return within(self, self.dropped[0], from) && within(self, self.dropped[1], to) && !within(self, self.dropped[1], from)
}

// focused reports whether `handle` or a node inside it has keyboard focus. Read keys and text
// from input.State while it does, unless it is editable: update_input edits it.
focused :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return within(self, self.focused, handle)
}

// focus gives `handle` keyboard focus, as a press on it would, its caret at the end of its text;
// none takes focus away.
focus :: proc(self: ^UI, handle: NodeHandle) {
  n, ok := node(self, handle)
  self.focused = handle if ok else {}
  if ok do self.caret, self.mark = len(n.text), len(n.text)
}

// changed reports whether this tick edited `handle`'s text, toggled it or dragged it.
changed :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return handle != {} && self.changed == handle
}

// submitted reports whether Enter was pressed in `handle`, an edited text, this tick.
submitted :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return handle != {} && self.submitted == handle
}

// selection returns the focused text's selection, byte offsets lo <= hi, the caret at one end;
// lo == hi is just the caret.
selection :: proc(self: ^UI) -> (lo, hi: int) {
  return min(self.caret, self.mark), max(self.caret, self.mark)
}

// copied returns the text Ctrl or Cmd with C or X copied this tick, for the clipboard; empty when
// none. It lives until the next update_input.
copied :: proc(self: ^UI) -> string {
  return self.copied
}
