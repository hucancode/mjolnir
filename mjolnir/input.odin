package mjolnir

import "core:c"
import "vendor:glfw"

// Frame-coherent input.
//
// GLFW callbacks write ONLY the `raw_*` accumulator (physical device state),
// every spin of the main loop. Once per update tick `input_new_frame` snaps
// that accumulator into `cur_*` and keeps the previous snapshot in `prev_*`,
// so edges (pressed / released) are defined frame-to-frame and stay valid for
// the whole tick — the way Unity's old Input.GetKeyDown behaves. This decouples
// the kHz event poll from the throttled update, which is what made the old
// per-poll edge detection miss button presses (see git history / examples).
Input :: struct {
  // raw accumulator — written by GLFW callbacks, read at snapshot time
  raw_buttons:  [8]bool,
  raw_keys:     [512]bool,
  raw_mouse:    [2]f64,
  scroll_accum: [2]f64, // summed between ticks so no wheel notch is lost

  // frame snapshot — rebuilt once per tick by input_new_frame
  cur_buttons:  [8]bool,
  prev_buttons: [8]bool,
  cur_keys:     [512]bool,
  prev_keys:    [512]bool,
  cur_mouse:    [2]f64,
  prev_mouse:   [2]f64,
  mouse_delta:  [2]f64,
  scroll:       [2]f64,

  // True for this tick when the debug UI owns the pointer. User callbacks and
  // polling edges are withheld while set; the UI reads the raw state itself.
  consumed_by_ui: bool,
  // Latches a button whose PRESS landed on the UI, so the matching RELEASE is
  // also withheld from user procs regardless of where the cursor travels.
  ui_owns_button: [8]bool,
}

// Promote the raw accumulator into the per-tick snapshot. Call exactly once at
// the start of each update tick, before any query or user callback.
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

// ---- raw writers, called from GLFW callbacks ----

input_set_button :: proc(self: ^Input, button: c.int, down: bool) {
  if button < 0 || int(button) >= len(self.raw_buttons) do return
  self.raw_buttons[button] = down
}

input_set_key :: proc(self: ^Input, key: c.int, down: bool) {
  if key < 0 || int(key) >= len(self.raw_keys) do return
  self.raw_keys[key] = down
}

input_set_mouse :: proc(self: ^Input, x, y: f64) {
  self.raw_mouse = {x, y}
}

input_add_scroll :: proc(self: ^Input, dx, dy: f64) {
  self.scroll_accum += {dx, dy}
}

// ---- queries, pure functions of the snapshot ----

input_key_down :: proc(self: ^Input, key: c.int) -> bool {
  if key < 0 || int(key) >= len(self.cur_keys) do return false
  return self.cur_keys[key]
}

input_key_pressed :: proc(self: ^Input, key: c.int) -> bool {
  if key < 0 || int(key) >= len(self.cur_keys) do return false
  return self.cur_keys[key] && !self.prev_keys[key]
}

input_key_released :: proc(self: ^Input, key: c.int) -> bool {
  if key < 0 || int(key) >= len(self.cur_keys) do return false
  return !self.cur_keys[key] && self.prev_keys[key]
}

input_mouse_down :: proc(self: ^Input, button: c.int) -> bool {
  if button < 0 || int(button) >= len(self.cur_buttons) do return false
  return self.cur_buttons[button]
}

input_mouse_pressed :: proc(self: ^Input, button: c.int) -> bool {
  if button < 0 || int(button) >= len(self.cur_buttons) do return false
  return self.cur_buttons[button] && !self.prev_buttons[button]
}

input_mouse_released :: proc(self: ^Input, button: c.int) -> bool {
  if button < 0 || int(button) >= len(self.cur_buttons) do return false
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

// Fan the per-tick snapshot edges out to the registered user callbacks, applying
// the debug-UI capture rules. Mouse buttons synthesize PRESS / RELEASE actions;
// REPEAT is intentionally dropped (the debug UI still gets it directly from the
// GLFW key callback). Call once per tick after input_new_frame.
input_dispatch_callbacks :: proc(engine: ^Engine) {
  inp := &engine.input
  for b in 0 ..< len(inp.cur_buttons) {
    pressed := inp.cur_buttons[b] && !inp.prev_buttons[b]
    released := !inp.cur_buttons[b] && inp.prev_buttons[b]
    if pressed {
      if inp.consumed_by_ui {
        inp.ui_owns_button[b] = true
      } else if engine.mouse_press_proc != nil {
        engine.mouse_press_proc(engine, b, int(glfw.PRESS), 0)
      }
    }
    if released {
      if inp.ui_owns_button[b] {
        inp.ui_owns_button[b] = false
      } else if engine.mouse_press_proc != nil {
        engine.mouse_press_proc(engine, b, int(glfw.RELEASE), 0)
      }
    }
  }
  if engine.key_press_proc != nil && !debug_ui_wants_keyboard(engine) {
    for k in 0 ..< len(inp.cur_keys) {
      if inp.cur_keys[k] && !inp.prev_keys[k] {
        engine.key_press_proc(engine, k, int(glfw.PRESS), 0)
      } else if !inp.cur_keys[k] && inp.prev_keys[k] {
        engine.key_press_proc(engine, k, int(glfw.RELEASE), 0)
      }
    }
  }
  if engine.mouse_move_proc != nil && !inp.consumed_by_ui {
    if inp.mouse_delta.x != 0 || inp.mouse_delta.y != 0 {
      engine.mouse_move_proc(engine, inp.cur_mouse, inp.mouse_delta)
    }
  }
  if engine.mouse_scroll_proc != nil && !inp.consumed_by_ui {
    if inp.scroll.x != 0 || inp.scroll.y != 0 {
      engine.mouse_scroll_proc(engine, inp.scroll)
    }
  }
}

// ---- engine-level convenience wrappers ----
//
// All edge queries read the per-tick input snapshot, so they are frame-coherent:
// stable for the whole update tick and reliable inside the `update` callback.

// True while `key` is currently held.
is_key_down :: proc(self: ^Engine, key: c.int) -> bool {
  return input_key_down(&self.input, key)
}

// True only on the tick `key` transitioned from up to down.
is_key_pressed :: proc(self: ^Engine, key: c.int) -> bool {
  return input_key_pressed(&self.input, key)
}

// True only on the tick `key` transitioned from down to up.
is_key_released :: proc(self: ^Engine, key: c.int) -> bool {
  return input_key_released(&self.input, key)
}

// True while mouse `button` is currently held.
is_mouse_down :: proc(self: ^Engine, button: c.int) -> bool {
  return input_mouse_down(&self.input, button)
}

// True only on the tick mouse `button` transitioned from up to down.
is_mouse_pressed :: proc(self: ^Engine, button: c.int) -> bool {
  return input_mouse_pressed(&self.input, button)
}

// True only on the tick mouse `button` transitioned from down to up.
is_mouse_released :: proc(self: ^Engine, button: c.int) -> bool {
  return input_mouse_released(&self.input, button)
}
