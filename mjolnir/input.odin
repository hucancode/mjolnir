package mjolnir

import "core:math"
import "core:unicode/utf8"
import "platform"
import "render"
import mu "vendor:microui"

// Fan this tick's input edges out to the user callbacks, withholding what the
// debug UI captures. Key REPEAT is not dispatched. Call once per tick after
// platform.input_new_frame.
@(private)
input_dispatch_callbacks :: proc(engine: ^Engine) {
  inp := &engine.platform.input
  for b in platform.MouseButton {
    if platform.input_mouse_pressed(inp, b) &&
       !render.debug_ui_claim_button(&engine.render, int(b), true) &&
       engine.mouse_press_proc != nil {
      engine.mouse_press_proc(engine, b, .PRESS)
    }
    if platform.input_mouse_released(inp, b) &&
       !render.debug_ui_claim_button(&engine.render, int(b), false) &&
       engine.mouse_press_proc != nil {
      engine.mouse_press_proc(engine, b, .RELEASE)
    }
  }
  if engine.key_press_proc != nil && !render.debug_ui_wants_keyboard(&engine.render) {
    for k in 0 ..< platform.MAX_KEYS {
      if inp.cur_keys[k] == inp.prev_keys[k] do continue
      engine.key_press_proc(engine, platform.Key(k), .PRESS if inp.cur_keys[k] else .RELEASE)
    }
  }
  if render.debug_ui_wants_mouse(&engine.render) do return
  if engine.mouse_move_proc != nil && inp.mouse_delta != {} {
    engine.mouse_move_proc(engine, inp.cur_mouse, inp.mouse_delta)
  }
  if engine.mouse_scroll_proc != nil && inp.scroll != {} {
    engine.mouse_scroll_proc(engine, inp.scroll)
  }
}

// Window events forwarded to the microui debug context as they arrive.
@(private)
debug_ui_hooks :: proc(engine: ^Engine) -> platform.EventHooks {
  return {
    key = proc(user: rawptr, key: platform.Key, action: platform.Action) {
      ctx := render.debug_ui(&(cast(^Engine)user).render)
      mk, ok := mu_key(key)
      if !ok do return
      if action == .RELEASE do mu.input_key_up(ctx, mk)
      else do mu.input_key_down(ctx, mk)
    },
    mouse_button = proc(user: rawptr, button: platform.MouseButton, action: platform.Action) {
      engine := cast(^Engine)user
      ctx := render.debug_ui(&engine.render)
      mb: mu.Mouse
      #partial switch button {
      case .LEFT:   mb = .LEFT
      case .RIGHT:  mb = .RIGHT
      case .MIDDLE: mb = .MIDDLE
      case:         return
      }
      p := engine.platform.input.raw_mouse
      x, y := i32(math.round(p.x)), i32(math.round(p.y))
      if action == .RELEASE do mu.input_mouse_up(ctx, x, y, mb)
      else do mu.input_mouse_down(ctx, x, y, mb)
    },
    cursor = proc(user: rawptr, x, y: f64) {
      ctx := render.debug_ui(&(cast(^Engine)user).render)
      mu.input_mouse_move(ctx, i32(math.round(x)), i32(math.round(y)))
    },
    scroll = proc(user: rawptr, dx, dy: f64) {
      ctx := render.debug_ui(&(cast(^Engine)user).render)
      mu.input_scroll(ctx, -i32(math.round(dx)), -i32(math.round(dy)))
    },
    char = proc(user: rawptr, ch: rune) {
      ctx := render.debug_ui(&(cast(^Engine)user).render)
      bytes, size := utf8.encode_rune(ch)
      mu.input_text(ctx, string(bytes[:size]))
    },
    user = engine,
  }
}

// microui models only editing and modifier keys; text arrives as chars.
@(private = "file")
mu_key :: proc(key: platform.Key) -> (mu.Key, bool) {
  #partial switch key {
  case .LEFT_SHIFT, .RIGHT_SHIFT:     return .SHIFT, true
  case .LEFT_CONTROL, .RIGHT_CONTROL: return .CTRL, true
  case .LEFT_ALT, .RIGHT_ALT:         return .ALT, true
  case .BACKSPACE:                    return .BACKSPACE, true
  case .DELETE:                       return .DELETE, true
  case .ENTER:                        return .RETURN, true
  case .LEFT:                         return .LEFT, true
  case .RIGHT:                        return .RIGHT, true
  case .HOME:                         return .HOME, true
  case .END:                          return .END, true
  case .A:                            return .A, true
  case .X:                            return .X, true
  case .C:                            return .C, true
  case .V:                            return .V, true
  }
  return .SHIFT, false
}
