// FSM on its own: a guard on a line patrols, chases an intruder and returns as a state machine, reporting what it decides. The command line prints it, the web page shows it.
package main

import "core:fmt"
import "core:strings"
import "mjolnir/fsm"

DT :: 0.5

out: strings.Builder

GuardState :: enum {
  PATROL,
  CHASE,
  RETURN,
}

Guard :: struct {
  position, heading: f32,
  intruder:          ^f32,
}

GUARD := [GuardState]fsm.State(Guard, GuardState) {
  .PATROL = {update = patrol, enter = proc(g: ^Guard) {say(g, "patrols")}},
  .CHASE  = {update = chase, enter = proc(g: ^Guard) {say(g, "spots the intruder")}},
  .RETURN = {update = go_back, enter = proc(g: ^Guard) {say(g, "gives up and returns")}},
}

patrol :: proc(g: ^Guard, dt: f32) -> GuardState {
  if abs(g.intruder^ - g.position) < 4 do return .CHASE
  g.position += g.heading * dt
  if abs(g.position) > 3 do g.heading = -g.heading
  return .PATROL
}

chase :: proc(g: ^Guard, dt: f32) -> GuardState {
  if abs(g.position) > 8 do return .RETURN
  g.position += 2 * dt if g.intruder^ > g.position else -2 * dt
  return .CHASE
}

go_back :: proc(g: ^Guard, dt: f32) -> GuardState {
  if abs(g.position) < 0.5 do return .PATROL
  g.position += -dt if g.position > 0 else dt
  return .RETURN
}

say :: proc(g: ^Guard, what: string) {
  fmt.sbprintfln(&out, "  guard at %.1f %s", g.position, what)
}

run :: proc() -> string {
  intruder := f32(-12)
  guard := Guard{heading = 1, intruder = &intruder}
  machine: fsm.Machine(GuardState)
  fsm.start(&machine, GUARD, &guard, .PATROL)
  for _ in 0 ..< 120 {
    intruder += 0.6 * DT
    fsm.update(&machine, GUARD, &guard, DT)
  }
  fmt.sbprintfln(&out, "  after 60s: %v at %.1f, intruder at %.1f", machine.current, guard.position, intruder)
  return strings.to_string(out)
}
