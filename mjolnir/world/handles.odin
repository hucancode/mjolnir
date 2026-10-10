package world

import cont "../containers"

// Untyped handle, for links stored outside world (e.g. a physics body's user).
Handle :: cont.Handle

NodeHandle :: distinct Handle

MAX_NODES_IN_SCENE :: 65536
// Despawned node slots stay reserved this many updates so consumers keyed by
// node index see the removal before the slot is reused.
RETIRE_GRACE :: 3
