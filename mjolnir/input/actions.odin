package input

// Source is one input an action listens to: a held key or button reads 1, an axis its value.
Source :: union {
  Key,
  MouseButton,
  GamepadButton,
  GamepadAxis,
}

// Binding is what drives one action of the game's own action enum: the action's value adds
// the positive sources and subtracts the negative ones. The action_* procs take a table of them:
//   Action :: enum { JUMP, MOVE_X }
//   BINDINGS := [Action]input.Binding {
//     .JUMP   = {positive = {input.Key.SPACE, input.GamepadButton.A}},
//     .MOVE_X = {positive = {input.Key.D, input.GamepadAxis.LEFT_X}, negative = {input.Key.A}},
//   }
//   if input.action_pressed(&s, BINDINGS, .JUMP) {...}
//   x := input.action_value(&s, BINDINGS, .MOVE_X)
Binding :: struct {
  positive: []Source,
  negative: []Source,
}

// AXIS_DEADZONE is how far an axis moves from rest before an action reads it.
AXIS_DEADZONE :: 0.15

// action_value returns the action's value in [-1, 1]; gamepad sources read gamepad `pad`.
action_value :: proc(self: ^State, bindings: [$A]Binding, action: A, pad := 0) -> f32 {
  v: f32
  for src in bindings[action].positive do v += source_value(self, src, pad, false)
  for src in bindings[action].negative do v -= source_value(self, src, pad, false)
  return clamp(v, -1, 1)
}

// action_down reports whether the action's value is at least half way.
action_down :: proc(self: ^State, bindings: [$A]Binding, action: A, pad := 0) -> bool {
  return action_value(self, bindings, action, pad) >= 0.5
}

// action_pressed reports whether a positive source went down this tick (an axis: past half way).
action_pressed :: proc(self: ^State, bindings: [$A]Binding, action: A, pad := 0) -> bool {
  for src in bindings[action].positive do if source_edge(self, src, pad, true) do return true
  return false
}

// action_released reports whether a positive source went up this tick (an axis: back under half
// way).
action_released :: proc(self: ^State, bindings: [$A]Binding, action: A, pad := 0) -> bool {
  for src in bindings[action].positive do if source_edge(self, src, pad, false) do return true
  return false
}

// The source's value this tick, or the last tick's for an axis when `last`.
@(private)
source_value :: proc(self: ^State, src: Source, pad: int, last: bool) -> f32 {
  switch s in src {
  case Key: return f32(int(key_down(self, s)))
  case MouseButton: return f32(int(mouse_down(self, s)))
  case GamepadButton: return f32(int(gamepad_down(self, pad, s)))
  case GamepadAxis:
    if !pad_valid(pad) do return 0
    v := self.gamepad_axes_last[pad][s] if last else self.gamepad_axes[pad][s]
    return v if abs(v) > AXIS_DEADZONE else 0
  }
  return 0
}

@(private)
source_edge :: proc(self: ^State, src: Source, pad: int, pressed: bool) -> bool {
  switch s in src {
  case Key: return key_pressed(self, s) if pressed else key_released(self, s)
  case MouseButton: return mouse_pressed(self, s) if pressed else mouse_released(self, s)
  case GamepadButton: return gamepad_pressed(self, pad, s) if pressed else gamepad_released(self, pad, s)
  case GamepadAxis:
    was, now := source_value(self, s, pad, true) >= 0.5, source_value(self, s, pad, false) >= 0.5
    return now && !was if pressed else was && !now
  }
  return false
}
