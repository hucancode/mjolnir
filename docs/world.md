---
title: World
---

Layer 2. The logical scene graph. World says *where* things are,
never what they look like or how they move: meshes, materials, lights
and cameras live in [render](render.html), skeletons and poses in
[animation](animation.html). It imports only `containers` and
`geometry`, and runs headless (tests, servers, navmesh baking).

## Scene graph

A `Node` carries a `Transform`, a parent and children, its own and
inherited visibility, a name, and `tags: u32`, a bit set the
application defines. Lookups go through generational `NodeHandle`s:
`node(&w, h)` resolves one, `valid(&w, h)` checks it.

- `spawn` / `spawn_child` / `despawn` manage nodes.
- `translate`, `rotate`, `scale` and their `_by` variants edit the
  local transform; `set_local_matrix` sets it from a matrix.
- `set_world_pose` writes a world-space pose, solving the local
  transform against the parent. Physics glue uses it.
- `world_matrix` reads a node's world matrix.
- `set_visible` hides a node and its subtree.
- `tag` / `untag` set and clear tag bits.

## Update and change feed

`world.update(&w)` walks the dirty subtrees and recomputes world
matrices; nothing recomputes unless something upstream moved. It
takes no time step because nothing in world moves on its own.

Each update publishes what changed since the previous one:

- `changed_nodes` — `{index, world_matrix, visible}` per moved or
  toggled node.
- `removed_nodes` — indices of despawned nodes.

Consumers key on the node index. A despawned node's index stays
reserved for `RETIRE_GRACE` updates so every consumer sees the
removal before the index is reused. See [glue](glue.html) for the
standard world → render loop.

## Loading

`mjolnir.load_gltf` creates world nodes, render meshes and materials,
and animation rigs in one pass. It lives in layer 3 because it spans
three modules.
