// FSM and behavior tree on their own: a guard on a line patrols, chases an intruder and returns as a state machine, while a worker gathers, delivers and eats by a behavior tree. Prints what each decides.
package main

import "core:fmt"
import bt "mjolnir/behavior_tree"
import "mjolnir/fsm"

DT :: 0.5

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
  fmt.printfln("  guard at %.1f %s", g.position, what)
}

Worker :: struct {
  hunger, carried, delivered: int,
}

WORKER := bt.Behavior(Worker)(bt.Sequence(Worker){{
  bt.Condition(Worker){"hungry", proc(w: ^Worker) -> bool {return w.hunger > 6}, {bt.Action(Worker){"eat", eat}}},
  bt.Condition(Worker){"full hands", proc(w: ^Worker) -> bool {return w.carried >= 3}, {bt.Action(Worker){"deliver", deliver}}},
  bt.Action(Worker){"gather", gather},
}})

eat :: proc(w: ^Worker) -> bt.Status {
  w.hunger -= 3
  return .RUNNING if w.hunger > 0 else .SUCCESS
}

deliver :: proc(w: ^Worker) -> bt.Status {
  w.delivered += w.carried
  w.carried = 0
  return .SUCCESS
}

gather :: proc(w: ^Worker) -> bt.Status {
  w.carried += 1
  return .RUNNING
}

main :: proc() {
  intruder := f32(-12)
  guard := Guard{heading = 1, intruder = &intruder}
  machine: fsm.Machine(GuardState)
  fmt.println("guard (fsm):")
  fsm.start(&machine, GUARD, &guard, .PATROL)
  for _ in 0 ..< 120 {
    intruder += 0.6 * DT
    fsm.update(&machine, GUARD, &guard, DT)
  }
  fmt.printfln("  after 60s: %v at %.1f, intruder at %.1f", machine.current, guard.position, intruder)

  fmt.println("worker (behavior tree):")
  worker: Worker
  trace := make([dynamic]bt.Step, context.temp_allocator)
  for tick in 0 ..< 12 {
    clear(&trace)
    worker.hunger += 1
    status := bt.tick(WORKER, &worker, &trace)
    fmt.printf("  tick %d %v", tick, status)
    for s in trace do fmt.printf(" %s:%v", s.name, s.status)
    fmt.printfln("  (hunger %d, carried %d, delivered %d)", worker.hunger, worker.carried, worker.delivered)
  }
}
