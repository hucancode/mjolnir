package fsm

// State is what an agent does while in one state of S. Every proc is optional. update returns
// the state to move to; its own state stays.
State :: struct($T: typeid, $S: typeid) {
  enter:  proc(agent: ^T),
  update: proc(agent: ^T, dt: f32) -> S,
  exit:   proc(agent: ^T),
}

// Machine is the state an agent is in and for how long.
Machine :: struct($S: typeid) {
  current: S,
  time:    f32, // seconds since current was entered
}

// start puts the machine in `state` and enters it.
start :: proc(self: ^Machine($S), states: [S]State($T, S), agent: ^T, state: S) {
  self^ = {current = state}
  if enter := states[state].enter; enter != nil do enter(agent)
}

// update runs the current state for dt seconds and moves to the state it returns.
update :: proc(self: ^Machine($S), states: [S]State($T, S), agent: ^T, dt: f32) {
  self.time += dt
  run := states[self.current].update
  if run == nil do return
  if next := run(agent, dt); next != self.current do change(self, states, agent, next)
}

// change leaves the current state and enters `next`, even when they are the same.
change :: proc(self: ^Machine($S), states: [S]State($T, S), agent: ^T, next: S) {
  if exit := states[self.current].exit; exit != nil do exit(agent)
  self.current = next
  self.time = 0
  if enter := states[next].enter; enter != nil do enter(agent)
}
