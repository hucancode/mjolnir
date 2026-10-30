#+build !js
#+private file
package input

import "core:testing"

@(test)
test_key_edge_order :: proc(t: ^testing.T) {
	s, acc: State
	key_event(&acc, .A, .PRESS)
	key_event(&acc, .A, .RELEASE)
	key_event(&acc, .B, .PRESS)
	drain(&acc, &s)
	key_event(&acc, .B, .RELEASE)
	key_event(&acc, .B, .PRESS)
	drain(&acc, &s)
	it := 0
	k, p, ok := next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && !p, "re-pressed key: release first")
	k, p, ok = next_key_edge(&s, &it)
	testing.expect(t, ok && k == .B && p, "then press")
	_, _, ok = next_key_edge(&s, &it)
	testing.expect(t, !ok, "no more edges")
	testing.expect(t, key_down(&s, .B) && !key_pressed(&s, .A), "state")
}

@(test)
test_gamepad_edges :: proc(t: ^testing.T) {
	s, acc: State
	axes: GamepadAxes
	axes[.LEFT_X] = 0.5
	gamepad_event(&acc, 1, true, {.A}, axes)
	drain(&acc, &s)
	testing.expect(t, 1 in s.gamepads && gamepad_pressed(&s, 1, .A) && gamepad_down(&s, 1, .A), "press")
	testing.expect(t, s.gamepad_axes[1][.LEFT_X] == 0.5, "axis")
	gamepad_event(&acc, 1, true, {.A}, axes)
	drain(&acc, &s)
	testing.expect(t, !gamepad_pressed(&s, 1, .A) && gamepad_down(&s, 1, .A), "held, no edge")
	gamepad_event(&acc, 1, false)
	drain(&acc, &s)
	testing.expect(t, 1 not_in s.gamepads && gamepad_released(&s, 1, .A) && s.gamepad_axes[1] == {}, "unplugged releases")
	testing.expect(t, !gamepad_down(&s, MAX_GAMEPADS, .A), "pad out of range")
}

Test_Action :: enum {
	JUMP,
	MOVE_X,
}

TEST_BINDINGS := [Test_Action]Binding {
	.JUMP   = {positive = {Key.SPACE, GamepadButton.A}},
	.MOVE_X = {positive = {Key.D, GamepadAxis.LEFT_X}, negative = {Key.A}},
}

@(test)
test_actions :: proc(t: ^testing.T) {
	s, acc: State
	key_event(&acc, .SPACE, .PRESS)
	key_event(&acc, .SPACE, .RELEASE)
	key_event(&acc, .A, .PRESS)
	drain(&acc, &s)
	testing.expect(t, action_pressed(&s, TEST_BINDINGS, .JUMP), "tap within a tick presses")
	testing.expect(t, action_value(&s, TEST_BINDINGS, .MOVE_X) == -1, "negative key")
	axes: GamepadAxes
	axes[.LEFT_X] = 0.8
	gamepad_event(&acc, 0, true, {}, axes)
	key_event(&acc, .A, .RELEASE)
	drain(&acc, &s)
	testing.expect(t, abs(action_value(&s, TEST_BINDINGS, .MOVE_X) - 0.8) < 1e-6, "stick")
	testing.expect(t, action_pressed(&s, TEST_BINDINGS, .MOVE_X) && action_down(&s, TEST_BINDINGS, .MOVE_X), "axis crossed half way")
	axes[.LEFT_X] = 0.1
	gamepad_event(&acc, 0, true, {}, axes)
	drain(&acc, &s)
	testing.expect(t, action_value(&s, TEST_BINDINGS, .MOVE_X) == 0, "deadzone")
	testing.expect(t, action_released(&s, TEST_BINDINGS, .MOVE_X), "axis back")
}
