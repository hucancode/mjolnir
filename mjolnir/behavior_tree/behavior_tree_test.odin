#+build !js
#+private
package behavior_tree

import "core:testing"

Probe :: struct {
  result: Status,
  ran:    int,
}

probe :: proc(p: ^Probe) -> Status {
  p.ran += 1
  return p.result
}

report :: proc(p: ^Probe) -> Status {
  return p.result
}

succeed :: proc(p: ^Probe) -> Status {
  return .SUCCESS
}

fail :: proc(p: ^Probe) -> Status {
  return .FAILURE
}

running :: proc(p: ^Probe) -> Status {
  return .RUNNING
}

never :: proc(p: ^Probe) -> bool {
  return false
}

always :: proc(p: ^Probe) -> bool {
  return true
}

@(test)
test_sequence_stops_at_first_unsuccessful :: proc(t: ^testing.T) {
  for result in ([2]Status{.FAILURE, .RUNNING}) {
    p := Probe{result = result}
    tree := Behavior(Probe)(Sequence(Probe){{Action(Probe){"report", report}, Action(Probe){"probe", probe}}})
    testing.expect_value(t, tick(tree, &p), result)
    testing.expect_value(t, p.ran, 0)
  }
}

@(test)
test_selector_stops_at_first_unfailed :: proc(t: ^testing.T) {
  for result in ([2]Status{.SUCCESS, .RUNNING}) {
    p := Probe{result = result}
    tree := Behavior(Probe)(Selector(Probe){{Action(Probe){"fail", fail}, Action(Probe){"probe", probe}, Action(Probe){"probe", probe}}})
    testing.expect_value(t, tick(tree, &p), result)
    testing.expect_value(t, p.ran, 1)
  }
}

@(test)
test_condition_guards_children :: proc(t: ^testing.T) {
  for result in Status {
    p := Probe{result = result}
    testing.expect_value(t, tick(Behavior(Probe)(Condition(Probe){"never", never, {Action(Probe){"probe", probe}}}), &p), Status.SUCCESS)
    testing.expect_value(t, p.ran, 0)
    testing.expect_value(t, tick(Behavior(Probe)(Condition(Probe){"always", always, {Action(Probe){"probe", probe}}}), &p), result)
    testing.expect_value(t, p.ran, 1)
  }
}

@(test)
test_empty_composites :: proc(t: ^testing.T) {
  p: Probe
  testing.expect_value(t, tick(Behavior(Probe)(Sequence(Probe){}), &p), Status.SUCCESS)
  testing.expect_value(t, tick(Behavior(Probe)(Selector(Probe){}), &p), Status.FAILURE)
}

NESTED := Behavior(Probe)(Sequence(Probe){{
  Condition(Probe){"never", never, {Action(Probe){"unreached", fail}}},
  Condition(Probe){"always", always, {Action(Probe){"succeed", succeed}, Action(Probe){"running", running}}},
  Action(Probe){"after", succeed},
}})

@(test)
test_nested_tree_and_trace :: proc(t: ^testing.T) {
  p: Probe
  trace: [dynamic]Step
  defer delete(trace)
  testing.expect_value(t, tick(NESTED, &p, &trace), Status.RUNNING)
  expected := [?]Step{{"succeed", .SUCCESS}, {"running", .RUNNING}}
  testing.expect_value(t, len(trace), len(expected))
  for step, i in expected do testing.expect_value(t, trace[i], step)
  testing.expect_value(t, tick(NESTED, &p), Status.RUNNING)
}
