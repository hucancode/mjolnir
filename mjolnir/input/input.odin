package input

import "core:unicode/utf8"

// Frame-coherent input.
//
// A window writes device events into an Accumulator as they arrive. Once per
// tick `new_frame` drains it into a State snapshot, so every query below is
// stable for the whole tick, independent of how often events are polled.
// Presses and releases are recorded per event: a tap that starts and ends
// between two ticks still reports both edges.

KeySet :: [MAX_KEYS]bool
ButtonSet :: bit_set[MouseButton]

TEXT_CAPACITY :: 128

// Raw device state written by the window. Only the window and new_frame
// touch it.
Accumulator :: struct {
  keys:             KeySet,
  keys_pressed:     KeySet,
  keys_released:    KeySet,
  keys_repeated:    KeySet,
  buttons:          ButtonSet,
  buttons_pressed:  ButtonSet,
  buttons_released: ButtonSet,
  cursor:           [2]f32,
  scroll:           [2]f32, // summed between ticks so no wheel notch is lost
  text:             [TEXT_CAPACITY]u8,
  text_len:         int,
}

// One tick of input.
State :: struct {
  keys:             KeySet,
  keys_pressed:     KeySet,
  keys_released:    KeySet,
  keys_repeated:    KeySet,
  buttons:          ButtonSet,
  buttons_pressed:  ButtonSet,
  buttons_released: ButtonSet,
  cursor:           [2]f32, // window pixels, origin top-left
  mouse_delta:      [2]f32,
  scroll:           [2]f32,
  text_buf:         [TEXT_CAPACITY]u8,
  text_len:         int,
  primed:           bool, // cursor seen once; the first tick has no delta
  // Set by the first consumer that claims the device this tick (debug UI,
  // then game UI). Later consumers skip a captured device.
  mouse_captured:    bool,
  keyboard_captured: bool,
}

// Drain the accumulator into this tick's snapshot. Call once per tick, before
// any query.
new_frame :: proc(self: ^State, acc: ^Accumulator) {
  prev_cursor := self.cursor if self.primed else acc.cursor
  self.keys = acc.keys
  self.keys_pressed = acc.keys_pressed
  self.keys_released = acc.keys_released
  self.keys_repeated = acc.keys_repeated
  self.buttons = acc.buttons
  self.buttons_pressed = acc.buttons_pressed
  self.buttons_released = acc.buttons_released
  self.cursor = acc.cursor
  self.mouse_delta = acc.cursor - prev_cursor
  self.scroll = acc.scroll
  self.text_buf = acc.text
  self.text_len = acc.text_len
  self.primed = true
  self.mouse_captured = false
  self.keyboard_captured = false
  acc.keys_pressed = {}
  acc.keys_released = {}
  acc.keys_repeated = {}
  acc.buttons_pressed = {}
  acc.buttons_released = {}
  acc.scroll = {}
  acc.text_len = 0
}

// ---- accumulator writers, called by the window ----

on_key :: proc(acc: ^Accumulator, key: Key, action: Action) {
  if !key_valid(key) do return
  k := int(key)
  switch action {
  case .PRESS:
    acc.keys[k] = true
    acc.keys_pressed[k] = true
  case .REPEAT:
    acc.keys_repeated[k] = true
  case .RELEASE:
    acc.keys[k] = false
    acc.keys_released[k] = true
  }
}

on_button :: proc(acc: ^Accumulator, button: MouseButton, action: Action) {
  if button < min(MouseButton) || button > max(MouseButton) do return
  if action == .RELEASE {
    acc.buttons -= {button}
    acc.buttons_released += {button}
  } else {
    acc.buttons += {button}
    acc.buttons_pressed += {button}
  }
}

on_cursor :: proc(acc: ^Accumulator, x, y: f32) {
  acc.cursor = {x, y}
}

on_scroll :: proc(acc: ^Accumulator, dx, dy: f32) {
  acc.scroll += {dx, dy}
}

// Append a typed character; dropped when the tick's text buffer is full.
on_char :: proc(acc: ^Accumulator, ch: rune) {
  bytes, size := utf8.encode_rune(ch)
  if acc.text_len + size > TEXT_CAPACITY do return
  copy(acc.text[acc.text_len:], bytes[:size])
  acc.text_len += size
}

// ---- queries, pure functions of the snapshot ----

key_down :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys[key]
}

key_pressed :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_pressed[key]
}

key_released :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_released[key]
}

// OS key auto-repeat fired this tick (the key is held).
key_repeated :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_repeated[key]
}

mouse_down :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons
}

mouse_pressed :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons_pressed
}

mouse_released :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons_released
}

// Cursor position in window pixels.
cursor :: proc(self: ^State) -> [2]f32 {
  return self.cursor
}

mouse_delta :: proc(self: ^State) -> [2]f32 {
  return self.mouse_delta
}

scroll :: proc(self: ^State) -> [2]f32 {
  return self.scroll
}

// UTF-8 text typed this tick.
text :: proc(self: ^State) -> string {
  return string(self.text_buf[:self.text_len])
}

// -1 while only `neg` is held, +1 while only `pos` is held, else 0.
axis :: proc(self: ^State, neg, pos: Key) -> f32 {
  return f32(int(key_down(self, pos))) - f32(int(key_down(self, neg)))
}

// Iterate this tick's key edges. A key with both edges this tick yields them
// in the order that leaves it in its current state.
//   it := 0
//   for key, pressed in input.next_key_edge(&s, &it) {...}
next_key_edge :: proc(self: ^State, it: ^int) -> (key: Key, pressed: bool, ok: bool) {
  for it^ < 2 * MAX_KEYS {
    i, second := it^ / 2, it^ % 2 == 1
    p, r := self.keys_pressed[i], self.keys_released[i]
    if !p && !r || second && !(p && r) {
      it^ = 2 * (i + 1)
      continue
    }
    it^ += 1
    // both edges: down now means release came first
    release_first := p && r && self.keys[i]
    if p && r do return Key(i), release_first == second, true
    return Key(i), p, true
  }
  return
}

@(private)
key_valid :: proc(key: Key) -> bool {
  return i32(key) >= 0 && i32(key) < MAX_KEYS
}
