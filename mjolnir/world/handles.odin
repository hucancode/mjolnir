package world

import cont "../containers"

// Handle is an untyped handle, for links stored outside world (e.g. a physics body's user).
Handle :: cont.Handle

// NodeHandle identifies a node; stale after node_destroy.
NodeHandle :: distinct Handle

@(private)
MAX_NODES_IN_SCENE :: 65536
// RETIRE_GRACE is how many updates a despawned slot stays reserved, so index-keyed consumers see the removal.
@(private)
RETIRE_GRACE :: 3
