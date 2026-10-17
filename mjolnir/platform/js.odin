#+build js
package platform

import "base:runtime"
import "core:log"
import "core:unicode/utf8"
import "../input"
import js "core:sys/wasm/js"

// CANVAS_ID is the id of the page's <canvas> the engine draws into.
CANVAS_ID :: "canvas"

// Platform is the page's canvas, sized to its CSS box at the device pixel ratio. Must not
// move after init (the listeners keep a pointer to it). `window` is the canvas selector
// render.init takes.
Platform :: struct {
  window:  cstring,
  using _: Platform_State,
}

@(private)
Platform_State :: struct {
  // DOM events since the last read_input
  input:    Accumulator,
  context_: runtime.Context,
}

// init takes the canvas; width, height and title are the page's business, except the title.
init :: proc(self: ^Platform, width, height: u32, title: string) -> bool {
  self.window = "#" + CANVAS_ID
  self.context_ = context
  js.set_document_title(title)
  fit_canvas()
  js.add_window_event_listener(.Resize, self, on_resize)
  js.add_window_event_listener(.Key_Down, self, on_key)
  js.add_window_event_listener(.Key_Up, self, on_key)
  js.add_event_listener(CANVAS_ID, .Mouse_Down, self, on_mouse)
  js.add_window_event_listener(.Mouse_Up, self, on_mouse)
  js.add_window_event_listener(.Mouse_Move, self, on_mouse)
  js.add_event_listener(CANVAS_ID, .Wheel, self, on_wheel)
  return true
}

// shutdown leaves the page as it is.
shutdown :: proc(self: ^Platform) {}

// should_close is false: a page closes by going away.
should_close :: proc(self: ^Platform) -> bool {
  return false
}

// poll_events does nothing: the browser delivers events between animation frames.
poll_events :: proc(self: ^Platform) {}

// read_input takes this tick's input snapshot from the events received so far.
read_input :: proc(self: ^Platform, s: ^input.State) {
  acc_drain(&self.input, s)
}

// framebuffer_size returns the canvas size in pixels.
framebuffer_size :: proc(self: ^Platform) -> [2]u32 {
  return {u32(js.get_element_key_f64(CANVAS_ID, "width")), u32(js.get_element_key_f64(CANVAS_ID, "height"))}
}

// dpi_scale returns the device pixel ratio.
dpi_scale :: proc(self: ^Platform) -> f32 {
  return f32(js.device_pixel_ratio())
}

// The step run was given and the context to call it in: the browser calls it through step_js.
@(private = "file")
web: struct {
  step:     proc() -> bool,
  context_: runtime.Context,
}

// run hands step to the browser and returns at once: odin.js calls it each animation frame
// until it returns false.
run :: proc(step: proc() -> bool) {
  web = {step, context}
}

// Called by odin.js each animation frame; false ends the loop.
@(export, link_name = "step")
step_js :: proc "contextless" (dt: f64) -> bool {
  context = web.context_
  if web.step == nil do return false
  if web.step() do return true
  web.step = nil
  return false
}

// sleep does nothing: the browser paces the animation frames.
sleep :: proc(ms: f64) {}

// read_file fails: the web has no file system. #load the bytes instead.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
  log.errorf("Failed to read '%s': no file system on the web", path)
  return nil, false
}

// write_file fails: the web has no file system.
write_file :: proc(path: string, data: []u8) -> bool {
  log.errorf("Failed to write '%s': no file system on the web", path)
  return false
}

// The canvas backing store follows its CSS box at the device pixel ratio.
@(private = "file")
fit_canvas :: proc() {
  rect := js.get_bounding_client_rect(CANVAS_ID)
  ratio := js.device_pixel_ratio()
  js.set_element_key_f64(CANVAS_ID, "width", max(1, f64(int(rect.width * ratio))))
  js.set_element_key_f64(CANVAS_ID, "height", max(1, f64(int(rect.height * ratio))))
}

@(private = "file")
on_resize :: proc(e: js.Event) {
  fit_canvas()
}

@(private = "file")
on_key :: proc(e: js.Event) {
  self := cast(^Platform)e.user_data
  key, ok := key_of_code(e.key.code)
  if ok {
    action: input.Action = .RELEASE if e.kind == .Key_Up else (.REPEAT if e.key.repeat else .PRESS)
    acc_key(&self.input, key, action)
  }
  // a printable key's name is the character it types
  if e.kind == .Key_Down && !e.key.ctrl && !e.key.meta && utf8.rune_count(e.key.key) == 1 {
    r, _ := utf8.decode_rune(e.key.key)
    acc_char(&self.input, r)
  }
}

// Cursor positions are CSS pixels from the canvas corner, as GLFW's are window points.
@(private = "file")
on_mouse :: proc(e: js.Event) {
  self := cast(^Platform)e.user_data
  rect := js.get_bounding_client_rect(CANVAS_ID)
  acc_cursor(&self.input, f32(f64(e.mouse.client.x) - rect.x), f32(f64(e.mouse.client.y) - rect.y))
  if e.kind == .Mouse_Move do return
  // DOM buttons are left, middle, right
  button: input.MouseButton
  switch e.mouse.button {
  case 0: button = .LEFT
  case 1: button = .MIDDLE
  case 2: button = .RIGHT
  case: return
  }
  acc_button(&self.input, button, .RELEASE if e.kind == .Mouse_Up else .PRESS)
}

// A wheel notch is about 100 pixels; down is negative, as in GLFW.
@(private = "file")
on_wheel :: proc(e: js.Event) {
  self := cast(^Platform)e.user_data
  acc_scroll(&self.input, f32(-e.wheel.delta.x / 100), f32(-e.wheel.delta.y / 100))
}

// KeyboardEvent.code to Key; codes name physical keys, as GLFW key codes do.
@(private = "file")
key_of_code :: proc(code: string) -> (input.Key, bool) {
  switch code {
  case "Space": return .SPACE, true
  case "Quote": return .APOSTROPHE, true
  case "Comma": return .COMMA, true
  case "Minus": return .MINUS, true
  case "Period": return .PERIOD, true
  case "Slash": return .SLASH, true
  case "Semicolon": return .SEMICOLON, true
  case "Equal": return .EQUAL, true
  case "Digit0": return .NUM_0, true
  case "Digit1": return .NUM_1, true
  case "Digit2": return .NUM_2, true
  case "Digit3": return .NUM_3, true
  case "Digit4": return .NUM_4, true
  case "Digit5": return .NUM_5, true
  case "Digit6": return .NUM_6, true
  case "Digit7": return .NUM_7, true
  case "Digit8": return .NUM_8, true
  case "Digit9": return .NUM_9, true
  case "KeyA": return .A, true
  case "KeyB": return .B, true
  case "KeyC": return .C, true
  case "KeyD": return .D, true
  case "KeyE": return .E, true
  case "KeyF": return .F, true
  case "KeyG": return .G, true
  case "KeyH": return .H, true
  case "KeyI": return .I, true
  case "KeyJ": return .J, true
  case "KeyK": return .K, true
  case "KeyL": return .L, true
  case "KeyM": return .M, true
  case "KeyN": return .N, true
  case "KeyO": return .O, true
  case "KeyP": return .P, true
  case "KeyQ": return .Q, true
  case "KeyR": return .R, true
  case "KeyS": return .S, true
  case "KeyT": return .T, true
  case "KeyU": return .U, true
  case "KeyV": return .V, true
  case "KeyW": return .W, true
  case "KeyX": return .X, true
  case "KeyY": return .Y, true
  case "KeyZ": return .Z, true
  case "BracketLeft": return .LEFT_BRACKET, true
  case "Backslash": return .BACKSLASH, true
  case "BracketRight": return .RIGHT_BRACKET, true
  case "Backquote": return .GRAVE_ACCENT, true
  case "Escape": return .ESCAPE, true
  case "Enter": return .ENTER, true
  case "Tab": return .TAB, true
  case "Backspace": return .BACKSPACE, true
  case "Insert": return .INSERT, true
  case "Delete": return .DELETE, true
  case "ArrowRight": return .RIGHT, true
  case "ArrowLeft": return .LEFT, true
  case "ArrowDown": return .DOWN, true
  case "ArrowUp": return .UP, true
  case "PageUp": return .PAGE_UP, true
  case "PageDown": return .PAGE_DOWN, true
  case "Home": return .HOME, true
  case "End": return .END, true
  case "CapsLock": return .CAPS_LOCK, true
  case "F1": return .F1, true
  case "F2": return .F2, true
  case "F3": return .F3, true
  case "F4": return .F4, true
  case "F5": return .F5, true
  case "F6": return .F6, true
  case "F7": return .F7, true
  case "F8": return .F8, true
  case "F9": return .F9, true
  case "F10": return .F10, true
  case "F11": return .F11, true
  case "F12": return .F12, true
  case "ShiftLeft": return .LEFT_SHIFT, true
  case "ControlLeft": return .LEFT_CONTROL, true
  case "AltLeft": return .LEFT_ALT, true
  case "MetaLeft": return .LEFT_SUPER, true
  case "ShiftRight": return .RIGHT_SHIFT, true
  case "ControlRight": return .RIGHT_CONTROL, true
  case "AltRight": return .RIGHT_ALT, true
  case "MetaRight": return .RIGHT_SUPER, true
  }
  return {}, false
}
