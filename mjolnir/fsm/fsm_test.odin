#+build !js
#+private
package fsm

import "core:testing"

Light :: enum {
  RED,
  GREEN,
}

Signal :: struct {
  machine: Machine(Light),
  log:     [dynamic]string,
}

red_enter :: proc(s: ^Signal) {
  append(&s.log, "enter red")
}

red_exit :: proc(s: ^Signal) {
  append(&s.log, "exit red")
}

red_update :: proc(s: ^Signal, dt: f32) -> Light {
  return .GREEN if s.machine.time >= 1 else .RED
}

green_enter :: proc(s: ^Signal) {
  append(&s.log, "enter green")
}

LIGHTS := [Light]State(Signal, Light) {
  .RED   = {enter = red_enter, update = red_update, exit = red_exit},
  .GREEN = {enter = green_enter},
}

@(test)
test_start_update_change :: proc(t: ^testing.T) {
  s: Signal
  defer delete(s.log)
  start(&s.machine, LIGHTS, &s, .RED)
  update(&s.machine, LIGHTS, &s, 0.5)
  testing.expect_value(t, s.machine.current, Light.RED)
  testing.expect_value(t, s.machine.time, 0.5)
  update(&s.machine, LIGHTS, &s, 0.5)
  testing.expect_value(t, s.machine.current, Light.GREEN)
  testing.expect_value(t, s.machine.time, 0)
  update(&s.machine, LIGHTS, &s, 2)
  testing.expect_value(t, s.machine.current, Light.GREEN)
  testing.expect_value(t, s.machine.time, 2)
  change(&s.machine, LIGHTS, &s, .GREEN)
  testing.expect_value(t, s.machine.time, 0)
  expected := [?]string{"enter red", "exit red", "enter green", "enter green"}
  testing.expect_value(t, len(s.log), len(expected))
  for line, i in expected do testing.expect_value(t, s.log[i], line)
}
