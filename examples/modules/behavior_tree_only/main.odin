// Behavior tree on its own: a worker gathers, delivers and eats by a behavior tree, reporting each tick's trace. The command line prints it, the web page shows it.
package main

import "core:fmt"
import "core:strings"
import bt "mjolnir/behavior_tree"

out: strings.Builder

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

run :: proc() -> string {
  worker: Worker
  trace := make([dynamic]bt.Step, context.temp_allocator)
  for tick in 0 ..< 12 {
    clear(&trace)
    worker.hunger += 1
    status := bt.tick(WORKER, &worker, &trace)
    fmt.sbprintf(&out, "  tick %d %v", tick, status)
    for s in trace do fmt.sbprintf(&out, " %s:%v", s.name, s.status)
    fmt.sbprintfln(&out, "  (hunger %d, carried %d, delivered %d)", worker.hunger, worker.carried, worker.delivered)
  }
  return strings.to_string(out)
}
