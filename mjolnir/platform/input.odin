package platform

// Frame-coherent input.
//
// Window callbacks write only the raw accumulator, on every event poll. Once
// per update tick `input_new_frame` snaps it into `cur_*` and keeps the
// previous snapshot in `prev_*`, so pressed / released edges are defined
// tick-to-tick and stay valid for the whole tick, independent of how often
// events are polled.
Input :: struct {
  // raw accumulator, written by window callbacks
  raw_buttons:  [MouseButton]bool,
  raw_keys:     [MAX_KEYS]bool,
  raw_mouse:    [2]f64,
  scroll_accum: [2]f64, // summed between ticks so no wheel notch is lost

  // tick snapshot, rebuilt by input_new_frame
  cur_buttons:  [MouseButton]bool,
  prev_buttons: [MouseButton]bool,
  cur_keys:     [MAX_KEYS]bool,
  prev_keys:    [MAX_KEYS]bool,
  cur_mouse:    [2]f64,
  prev_mouse:   [2]f64,
  mouse_delta:  [2]f64,
  scroll:       [2]f64,
}

// Promote the raw accumulator into the tick snapshot. Call once at the start
// of each update tick, before any query.
input_new_frame :: proc(self: ^Input) {
  self.prev_buttons = self.cur_buttons
  self.cur_buttons = self.raw_buttons
  self.prev_keys = self.cur_keys
  self.cur_keys = self.raw_keys
  self.prev_mouse = self.cur_mouse
  self.cur_mouse = self.raw_mouse
  self.mouse_delta = self.cur_mouse - self.prev_mouse
  self.scroll = self.scroll_accum
  self.scroll_accum = {0, 0}
}

// ---- raw writers, called from window callbacks ----

input_set_button :: proc(self: ^Input, button: MouseButton, down: bool) {
  if button < min(MouseButton) || button > max(MouseButton) do return
  self.raw_buttons[button] = down
}

input_set_key :: proc(self: ^Input, key: Key, down: bool) {
  if !key_valid(key) do return
  self.raw_keys[key] = down
}

input_set_mouse :: proc(self: ^Input, x, y: f64) {
  self.raw_mouse = {x, y}
}

input_add_scroll :: proc(self: ^Input, dx, dy: f64) {
  self.scroll_accum += {dx, dy}
}

// ---- queries, pure functions of the snapshot ----

input_key_down :: proc(self: ^Input, key: Key) -> bool {
  return key_valid(key) && self.cur_keys[key]
}

input_key_pressed :: proc(self: ^Input, key: Key) -> bool {
  return key_valid(key) && self.cur_keys[key] && !self.prev_keys[key]
}

input_key_released :: proc(self: ^Input, key: Key) -> bool {
  return key_valid(key) && !self.cur_keys[key] && self.prev_keys[key]
}

input_mouse_down :: proc(self: ^Input, button: MouseButton) -> bool {
  return self.cur_buttons[button]
}

input_mouse_pressed :: proc(self: ^Input, button: MouseButton) -> bool {
  return self.cur_buttons[button] && !self.prev_buttons[button]
}

input_mouse_released :: proc(self: ^Input, button: MouseButton) -> bool {
  return !self.cur_buttons[button] && self.prev_buttons[button]
}

input_mouse_position :: proc(self: ^Input) -> [2]f64 {
  return self.cur_mouse
}

input_mouse_delta :: proc(self: ^Input) -> [2]f64 {
  return self.mouse_delta
}

input_scroll_delta :: proc(self: ^Input) -> [2]f64 {
  return self.scroll
}

@(private)
key_valid :: proc(key: Key) -> bool {
  return i32(key) >= 0 && i32(key) < MAX_KEYS
}
