package input

import "core:unicode/utf8"

// KeySet holds one flag per key, indexed by Key.
KeySet :: [MAX_KEYS]bool
// ButtonSet is a set of held or edged mouse buttons.
ButtonSet :: bit_set[MouseButton]

// TEXT_CAPACITY is the bytes of typed text kept per tick.
TEXT_CAPACITY :: 128

// Accumulator is raw device state written by the window. Only the window and new_frame
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

// State is one tick of input: the key_* and mouse_* queries read it, and its fields hold the
// cursor, its movement and the scroll in window pixels, plus which devices a consumer captured.
State :: struct {
  cursor:           [2]f32, // window pixels, origin top-left
  mouse_delta:      [2]f32,
  scroll:           [2]f32,
  // Set by the first consumer that claims the device this tick (debug UI,
  // then game UI). Later consumers skip a captured device.
  mouse_captured:    bool,
  keyboard_captured: bool,
  using _: State_Private,
}

@(private)
State_Private :: struct {
  keys:             KeySet,
  keys_pressed:     KeySet,
  keys_released:    KeySet,
  keys_repeated:    KeySet,
  buttons:          ButtonSet,
  buttons_pressed:  ButtonSet,
  buttons_released: ButtonSet,
  text_buf:         [TEXT_CAPACITY]u8,
  text_len:         int,
  primed:           bool, // cursor seen once; the first tick has no delta
}

// new_frame drains the accumulator into this tick's snapshot. Call once per tick, before
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

// on_key records a key event.
on_key :: proc(self: ^Accumulator, key: Key, action: Action) {
  if !key_valid(key) do return
  k := int(key)
  switch action {
  case .PRESS:
    self.keys[k] = true
    self.keys_pressed[k] = true
  case .REPEAT:
    self.keys_repeated[k] = true
  case .RELEASE:
    self.keys[k] = false
    self.keys_released[k] = true
  }
}

// on_button records a mouse button event.
on_button :: proc(self: ^Accumulator, button: MouseButton, action: Action) {
  if button < min(MouseButton) || button > max(MouseButton) do return
  if action == .RELEASE {
    self.buttons -= {button}
    self.buttons_released += {button}
  } else {
    self.buttons += {button}
    self.buttons_pressed += {button}
  }
}

// on_cursor records the cursor position in window pixels.
on_cursor :: proc(self: ^Accumulator, x, y: f32) {
  self.cursor = {x, y}
}

// on_scroll adds a scroll offset, summed until the next tick.
on_scroll :: proc(self: ^Accumulator, dx, dy: f32) {
  self.scroll += {dx, dy}
}

// on_char appends a typed character; dropped when the tick's text buffer is full.
on_char :: proc(self: ^Accumulator, ch: rune) {
  bytes, size := utf8.encode_rune(ch)
  if self.text_len + size > TEXT_CAPACITY do return
  copy(self.text[self.text_len:], bytes[:size])
  self.text_len += size
}

// key_down reports whether `key` is held.
key_down :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys[key]
}

// key_pressed reports whether `key` went down this tick.
key_pressed :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_pressed[key]
}

// key_released reports whether `key` went up this tick.
key_released :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_released[key]
}

// key_repeated reports OS key auto-repeat fired this tick (the key is held).
key_repeated :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_repeated[key]
}

// mouse_down reports whether `button` is held.
mouse_down :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons
}

// mouse_pressed reports whether `button` went down this tick.
mouse_pressed :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons_pressed
}

// mouse_released reports whether `button` went up this tick.
mouse_released :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons_released
}

// text returns the UTF-8 text typed this tick.
text :: proc(self: ^State) -> string {
  return string(self.text_buf[:self.text_len])
}

// axis returns -1 while only `neg` is held, +1 while only `pos` is held, else 0.
axis :: proc(self: ^State, neg, pos: Key) -> f32 {
  return f32(int(key_down(self, pos))) - f32(int(key_down(self, neg)))
}

// next_key_edge iterates this tick's key edges. A key with both edges this tick yields them
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
