// Input on its own: a scripted stream of window and gamepad events, fed and drained tick by tick as a window library would, and what the game asks of each tick through its own actions. The command line prints it, the web page shows it.
package main

import "core:fmt"
import "core:strings"
import "mjolnir/input"

Action :: enum {
  JUMP,
  MOVE,
}

BINDINGS := [Action]input.Binding {
  .JUMP = {positive = {input.Key.SPACE, input.GamepadButton.A}},
  .MOVE = {positive = {input.Key.D, input.GamepadAxis.LEFT_X}, negative = {input.Key.A}},
}

Tick :: struct {
  press:   []input.Key,
  release: []input.Key,
  click:   bool,
  cursor:  [2]f32,
  scroll:  f32,
  text:    string,
  pad:     input.GamepadButtonSet,
  stick:   f32,
}

SCRIPT := []Tick {
  {press = {.D}, cursor = {100, 100}},
  {cursor = {110, 104}},
  {press = {.A}, cursor = {130, 110}},
  {release = {.D}, click = true},
  {release = {.A}, scroll = 1},
  {text = "hi!", scroll = -2},
  {press = {.SPACE}},
  {release = {.SPACE}},
  {stick = -0.7},
  {stick = -0.7, pad = {.A}},
  {},
}

run :: proc() -> string {
  out: strings.Builder
  acc, state: input.State
  for t, frame in SCRIPT {
    for k in t.press do input.key_event(&acc, k, .PRESS)
    for k in t.release do input.key_event(&acc, k, .RELEASE)
    if t.click {
      input.button_event(&acc, .LEFT, .PRESS)
      input.button_event(&acc, .LEFT, .RELEASE)
    }
    if t.cursor != {} do input.cursor_event(&acc, t.cursor)
    if t.scroll != 0 do input.scroll_event(&acc, {0, t.scroll})
    for ch in t.text do input.char_event(&acc, ch)
    input.gamepad_event(&acc, 0, true, t.pad, #partial {.LEFT_X = t.stick})
    input.drain(&acc, &state)
    fmt.sbprintf(&out, "tick %d: move %v", frame, input.action_value(&state, BINDINGS, .MOVE))
    for it := 0; true; {
      key, pressed := input.next_key_edge(&state, &it) or_break
      fmt.sbprintf(&out, ", %v %s", key, "down" if pressed else "up")
    }
    if state.mouse_delta != {} do fmt.sbprintf(&out, ", mouse moved %v", state.mouse_delta)
    if input.mouse_pressed(&state, .LEFT) do fmt.sbprintf(&out, ", click at %v", state.cursor)
    if state.scroll != {} do fmt.sbprintf(&out, ", scroll %v", state.scroll.y)
    if s := input.text(&state); s != "" do fmt.sbprintf(&out, ", typed %q", s)
    for b in input.GamepadButton do if input.gamepad_pressed(&state, 0, b) do fmt.sbprintf(&out, ", pad %v down", b)
    if input.action_pressed(&state, BINDINGS, .JUMP) do fmt.sbprint(&out, ", jump!")
    fmt.sbprintln(&out)
  }
  return strings.to_string(out)
}
