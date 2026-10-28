package input

import "core:unicode/utf8"

// Feeding a State from a window's events: between ticks the *_event procs write the device
// events into an accumulating State (its scroll summed, so no wheel notch is lost), then drain
// moves it into the tick's State. Any window library can drive input this way.

// drain moves the accumulated events into this tick's State and clears their edges.
drain :: proc(acc, s: ^State) {
  prev_cursor := s.cursor if s.primed else acc.cursor
  s^ = acc^
  s.mouse_delta = acc.cursor - prev_cursor
  s.primed = true
  acc.keys_pressed = {}
  acc.keys_released = {}
  acc.keys_repeated = {}
  acc.buttons_pressed = {}
  acc.buttons_released = {}
  acc.scroll = {}
  acc.text_len = 0
}

// key_event records a key going down, repeating or up.
key_event :: proc(acc: ^State, key: Key, action: Action) {
  if !key_valid(key) do return
  switch action {
  case .PRESS:
    acc.keys[key] = true
    acc.keys_pressed[key] = true
  case .REPEAT:
    acc.keys_repeated[key] = true
  case .RELEASE:
    acc.keys[key] = false
    acc.keys_released[key] = true
  }
}

// button_event records a mouse button going down or up.
button_event :: proc(acc: ^State, button: MouseButton, action: Action) {
  if button < min(MouseButton) || button > max(MouseButton) do return
  if action == .RELEASE {
    acc.buttons -= {button}
    acc.buttons_released += {button}
  } else {
    acc.buttons += {button}
    acc.buttons_pressed += {button}
  }
}

// cursor_event records the cursor's position in window pixels, origin top-left.
cursor_event :: proc(acc: ^State, position: [2]f32) {
  acc.cursor = position
}

// scroll_event adds a wheel or trackpad scroll.
scroll_event :: proc(acc: ^State, delta: [2]f32) {
  acc.scroll += delta
}

// char_event appends a typed character; dropped once the tick's TEXT_CAPACITY is full.
char_event :: proc(acc: ^State, ch: rune) {
  bytes, size := utf8.encode_rune(ch)
  if acc.text_len + size > TEXT_CAPACITY do return
  copy(acc.text_buf[acc.text_len:], bytes[:size])
  acc.text_len += size
}
