package world

import cont "../containers"

Handle :: cont.Handle
Pool :: cont.Pool

NodeHandle :: distinct Handle

MAX_NODES_IN_SCENE :: 65536
// Despawned node slots stay reserved this many updates so consumers keyed by
// node index see the removal before the slot is reused.
RETIRE_GRACE :: 3
