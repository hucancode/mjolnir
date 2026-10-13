package input

import "core:math"
import mu "vendor:microui"

// feed_microui feeds one input tick to a microui context and captures the mouse and
// keyboard it owns. Call first among input consumers on the update tick.
feed_microui :: proc(s: ^State, ctx: ^mu.Context) {
  hovered := ctx.hover_root != nil
  x, y := i32(math.round(s.cursor.x)), i32(math.round(s.cursor.y))
  mu.input_mouse_move(ctx, x, y)
  for b in MouseButton {
    // a press over the debug UI belongs to it until the tick after release
    if mouse_pressed(s, b) && hovered do s.overlay_buttons += {b}
    else if !mouse_down(s, b) && !mouse_released(s, b) do s.overlay_buttons -= {b}
    mb: mu.Mouse
    #partial switch b {
    case .LEFT:   mb = .LEFT
    case .RIGHT:  mb = .RIGHT
    case .MIDDLE: mb = .MIDDLE
    case:         continue
    }
    if mouse_pressed(s, b) do mu.input_mouse_down(ctx, x, y, mb)
    if mouse_released(s, b) do mu.input_mouse_up(ctx, x, y, mb)
  }
  if s.scroll != {} {
    mu.input_scroll(ctx, -i32(math.round(s.scroll.x)), -i32(math.round(s.scroll.y)))
  }
  it := 0
  for key, pressed in next_key_edge(s, &it) {
    mk := mu_key(key) or_continue
    if pressed do mu.input_key_down(ctx, mk)
    else do mu.input_key_up(ctx, mk)
  }
  for key in Key {
    if !key_repeated(s, key) do continue
    if mk, ok := mu_key(key); ok do mu.input_key_down(ctx, mk)
  }
  if t := text(s); len(t) > 0 do mu.input_text(ctx, t)
  if ctx.hover_root != nil || s.overlay_buttons != {} do s.mouse_captured = true
  if ctx.focus_id != 0 do s.keyboard_captured = true
}

// microui models only editing and modifier keys; text arrives as chars.
@(private = "file")
mu_key :: proc(key: Key) -> (mu.Key, bool) {
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

