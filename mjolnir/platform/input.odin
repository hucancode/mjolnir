#+private
package platform

import "core:unicode/utf8"
import "../input"

// Accumulator is raw device state the window callbacks write between ticks; read_input
// drains it into an input.State.
Accumulator :: struct {
  keys:             input.KeySet,
  keys_pressed:     input.KeySet,
  keys_released:    input.KeySet,
  keys_repeated:    input.KeySet,
  buttons:          input.ButtonSet,
  buttons_pressed:  input.ButtonSet,
  buttons_released: input.ButtonSet,
  cursor:           [2]f32,
  scroll:           [2]f32, // summed between ticks so no wheel notch is lost
  text:             [input.TEXT_CAPACITY]u8,
  text_len:         int,
}

// acc_drain moves the accumulator into this tick's snapshot and clears its edges.
acc_drain :: proc(acc: ^Accumulator, s: ^input.State) {
  prev_cursor := s.cursor if s.primed else acc.cursor
  s.keys = acc.keys
  s.keys_pressed = acc.keys_pressed
  s.keys_released = acc.keys_released
  s.keys_repeated = acc.keys_repeated
  s.buttons = acc.buttons
  s.buttons_pressed = acc.buttons_pressed
  s.buttons_released = acc.buttons_released
  s.cursor = acc.cursor
  s.mouse_delta = acc.cursor - prev_cursor
  s.scroll = acc.scroll
  s.text_buf = acc.text
  s.text_len = acc.text_len
  s.primed = true
  s.mouse_captured = false
  s.keyboard_captured = false
  acc.keys_pressed = {}
  acc.keys_released = {}
  acc.keys_repeated = {}
  acc.buttons_pressed = {}
  acc.buttons_released = {}
  acc.scroll = {}
  acc.text_len = 0
}

acc_key :: proc(self: ^Accumulator, key: input.Key, action: input.Action) {
  if i32(key) < 0 || i32(key) >= input.MAX_KEYS do return
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

acc_button :: proc(self: ^Accumulator, button: input.MouseButton, action: input.Action) {
  if button < min(input.MouseButton) || button > max(input.MouseButton) do return
  if action == .RELEASE {
    self.buttons -= {button}
    self.buttons_released += {button}
  } else {
    self.buttons += {button}
    self.buttons_pressed += {button}
  }
}

acc_cursor :: proc(self: ^Accumulator, x, y: f32) {
  self.cursor = {x, y}
}

acc_scroll :: proc(self: ^Accumulator, dx, dy: f32) {
  self.scroll += {dx, dy}
}

// acc_char appends a typed character; dropped when the tick's text buffer is full.
acc_char :: proc(self: ^Accumulator, ch: rune) {
  bytes, size := utf8.encode_rune(ch)
  if self.text_len + size > input.TEXT_CAPACITY do return
  copy(self.text[self.text_len:], bytes[:size])
  self.text_len += size
}
