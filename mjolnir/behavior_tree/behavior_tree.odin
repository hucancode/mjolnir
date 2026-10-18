package behavior_tree

// Status is what an action, and so a whole tree, reports for one tick.
Status :: enum {
  FAILURE,
  SUCCESS,
  RUNNING,
}

// Action is a named check or step run on the agent; conditions are actions too.
Action :: struct($T: typeid) {
  name: string,
  run:  proc(agent: ^T) -> Status,
}

// Sequence runs its children in order until one does not succeed, and reports that one;
// SUCCESS when all do.
Sequence :: struct($T: typeid) {
  children: []Behavior(T),
}

// Selector runs its children in order until one does not fail, and reports that one; FAILURE
// when all do.
Selector :: struct($T: typeid) {
  children: []Behavior(T),
}

// Behavior is a tree node: an action or a composite of more nodes.
Behavior :: union($T: typeid) {
  Action(T),
  Sequence(T),
  Selector(T),
}

// Step is an action that ran during a tick and what it reported.
Step :: struct {
  name:   string,
  status: Status,
}

// tick evaluates the tree from its root for agent and returns the root's status. Ticks keep no
// memory: a RUNNING action is reached again by evaluating the tree anew, so state belongs to the
// agent. Each action run is appended to trace when one is given.
tick :: proc(b: Behavior($T), agent: ^T, trace: ^[dynamic]Step = nil) -> Status {
  switch node in b {
  case Action(T):
    status := node.run(agent)
    if trace != nil do append(trace, Step{node.name, status})
    return status
  case Sequence(T):
    for child in node.children do if status := tick(child, agent, trace); status != .SUCCESS do return status
    return .SUCCESS
  case Selector(T):
    for child in node.children do if status := tick(child, agent, trace); status != .FAILURE do return status
    return .FAILURE
  }
  return .FAILURE
}
