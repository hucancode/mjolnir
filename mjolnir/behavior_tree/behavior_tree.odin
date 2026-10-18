package behavior_tree

// Status is what a node, and so a whole tree, reports for one tick.
Status :: enum {
  FAILURE,
  SUCCESS,
  RUNNING,
}

// Condition guards its children with a named question about the agent: when the answer is no
// it succeeds without running them; when yes it runs them as a Sequence and reports theirs.
Condition :: struct($T: typeid) {
  name:     string,
  test:     proc(agent: ^T) -> bool,
  children: []Behavior(T),
}

// Action is a named step the agent takes; it reports RUNNING while it is under way.
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

// Behavior is a tree node: a condition, an action or a composite of more nodes.
Behavior :: union($T: typeid) {
  Condition(T),
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
  case Condition(T):
    if !node.test(agent) do return .SUCCESS
    return tick(Behavior(T)(Sequence(T){node.children}), agent, trace)
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
