---
title: World
---

Layer 2. The logical scene graph. World says *where* things are,
never what they look like or how they move: meshes, materials, lights
and cameras live in [render](render.html), skeletons and poses in
[animation](animation.html). It imports only `containers` and
`geometry`, and runs headless (tests, servers, navmesh baking).

## Scene graph

A node carries a local transform (position, rotation, scale), a
parent and children, its own and inherited visibility, a name, and a
`u32` tag bit set the application defines. Nodes are addressed by
generational `NodeHandle`s. `node(&w, h)` returns `(^Node, bool)`;
read `n.name`, `n.children`, `n.transform.position` (and the rest of
`Transform`) through it, and assign `n.name` directly. Change the
transform, hierarchy and visibility through the procs below so the
dirty flags stay correct. Procs given a stale handle do nothing
(setters) or return a default (getters).

- `spawn` / `spawn_child` / `despawn` manage nodes; `valid(&w, h)`
  checks a handle. `w.root` is the root node.
- `translate`, `rotate`, `rotate_by`, `scale` and `scale_xyz` edit the
  local transform; `set_local` sets position, rotation and scale at
  once and `set_local_matrix` sets them from a matrix.
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
removal before the index is reused. See [engine](engine.html#wiring-modules) for the
standard world → render loop.

## Loading

`mjolnir.load_gltf` creates world nodes, render meshes and materials,
and animation rigs in one pass. It lives in layer 3 because it spans
three modules; the per-module parts are `render/gltf` and
`animation/gltf`.
