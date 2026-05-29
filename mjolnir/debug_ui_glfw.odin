package mjolnir

// GLFW → microui input adapters. The render/debug_ui package owns the
// microui context but does not depend on GLFW; these helpers live here so
// the engine GLFW callbacks can stay almost empty.

import "core:math"
import "core:unicode/utf8"
import "vendor:glfw"
import mu "vendor:microui"

// Translate a GLFW key code to the matching microui key. Returns false for
// keys microui does not model (most printable characters arrive via the char
// callback instead).
@(private)
mu_key_for_glfw :: proc(key: i32) -> (mu.Key, bool) {
  switch key {
  case glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT:     return .SHIFT, true
  case glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL: return .CTRL, true
  case glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT:         return .ALT, true
  case glfw.KEY_BACKSPACE:                            return .BACKSPACE, true
  case glfw.KEY_DELETE:                               return .DELETE, true
  case glfw.KEY_ENTER:                                return .RETURN, true
  case glfw.KEY_LEFT:                                 return .LEFT, true
  case glfw.KEY_RIGHT:                                return .RIGHT, true
  case glfw.KEY_HOME:                                 return .HOME, true
  case glfw.KEY_END:                                  return .END, true
  case glfw.KEY_A:                                    return .A, true
  case glfw.KEY_X:                                    return .X, true
  case glfw.KEY_C:                                    return .C, true
  case glfw.KEY_V:                                    return .V, true
  }
  return .SHIFT, false
}

@(private)
mu_mouse_for_glfw :: proc(button: i32) -> (mu.Mouse, bool) {
  switch button {
  case glfw.MOUSE_BUTTON_LEFT:   return .LEFT, true
  case glfw.MOUSE_BUTTON_RIGHT:  return .RIGHT, true
  case glfw.MOUSE_BUTTON_MIDDLE: return .MIDDLE, true
  }
  return .LEFT, false
}

@(private)
dispatch_glfw_key :: proc(ctx: ^mu.Context, key, action: i32) {
  mk, ok := mu_key_for_glfw(key)
  if !ok do return
  switch action {
  case glfw.PRESS, glfw.REPEAT: mu.input_key_down(ctx, mk)
  case glfw.RELEASE:            mu.input_key_up(ctx, mk)
  }
}

@(private)
dispatch_glfw_mouse_button :: proc(
  ctx: ^mu.Context,
  button, action: i32,
  x, y: i32,
) {
  mb, ok := mu_mouse_for_glfw(button)
  if !ok do return
  switch action {
  case glfw.PRESS, glfw.REPEAT: mu.input_mouse_down(ctx, x, y, mb)
  case glfw.RELEASE:            mu.input_mouse_up(ctx, x, y, mb)
  }
}

@(private)
dispatch_glfw_cursor_pos :: proc(ctx: ^mu.Context, xpos, ypos: f64) -> (i32, i32) {
  x := i32(math.round(xpos))
  y := i32(math.round(ypos))
  mu.input_mouse_move(ctx, x, y)
  return x, y
}

@(private)
dispatch_glfw_scroll :: proc(ctx: ^mu.Context, xoffset, yoffset: f64) {
  mu.input_scroll(ctx, -i32(math.round(xoffset)), -i32(math.round(yoffset)))
}

@(private)
dispatch_glfw_char :: proc(ctx: ^mu.Context, ch: rune) {
  bytes, size := utf8.encode_rune(ch)
  mu.input_text(ctx, string(bytes[:size]))
}
