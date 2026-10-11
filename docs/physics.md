---
title: Physics
---

Layer 2. Rigid-body dynamics, collisions, spatial queries. Physics knows
nothing about the scene graph: the application owns a `physics.World`,
steps it in `update`, and copies `body_poses` back into world nodes
(see [engine](engine.html#wiring-modules)). Every body carries a `user`
handle for that link; bodies are destroyed explicitly, not with their
node, except dynamic bodies that fall below `KILL_Y` (see below).

## Step layout

```
cache this frame's contact impulses (for warmstart)
CCD: sweep fast dynamic bodies against static geometry, park them before impact
rebuild a BVH if bodies were created or changed role
if any body is awake:
  refit dynamic BVH
  broadphase (BVH tree-vs-tree) → narrowphase manifolds (speculative margin)
  prepare contacts (effective masses, friction basis)
  substep loop × NUM_SUBSTEPS:
    integrate velocities (gravity, forces, damping)
    warm start
    solve with soft bias
    integrate positions
    relax (solve without bias)
  restitution pass
  clear forces, refresh cached bounds
destroy dynamic bodies below KILL_Y
sensor overlaps
island sleep
```

## Why this shape

- **Collide once, solve in substeps (TGS-soft).** Contacts are built
  once per frame; each substep recovers the current separation from
  how far the bodies moved. The penetration bias is a soft spring
  whose energy the relax pass removes, so stacks rest without jitter.
- **BVH broadphase, not grid.** Dense and sparse scenes both work
  without tuning. Moving bodies live in a refit-every-frame BVH;
  static bodies in a separate one that is only rebuilt when it changes.
- **Speculative contacts plus CCD only when needed.** Contacts are
  created slightly before touch, which stops moderate-speed tunneling.
  A swept test fires only when a body moves more than half its
  smallest extent in one frame.
- **Island sleep.** Touching dynamic bodies sleep together once every
  member has been still for `SLEEP_TIME_THRESHOLD`.

## World

`init(&w, gravity, thread_count)` and `shutdown(&w)` own the world.
`thread_count = 0` starts one worker per CPU core; `1` runs everything
on the calling thread. `teardown(&w)` destroys every body but keeps
the world ready for reuse. `step(&w, dt)` advances one frame in
`NUM_SUBSTEPS` substeps; to pause, skip the call. `w.gravity` is read
every step. After each step `w.last_perf` holds a `PerfFrame` of
timings and counters, `w.contacts` the frame's contact manifolds and
`w.sensor_overlaps` the sensor overlaps (read-only).

A dynamic body that falls below `KILL_Y` (default `-50`, override with
`-define:PHYSICS_KILL_Y=...`) is destroyed during `step` and listed in
`w.killed` as a `KilledBody{body, user}` for that frame only. The
handle is already stale; use `user` to drop the scene node:

```odin
physics.step(&phys, dt)
for k in phys.killed do world.despawn(&app.scene, world.NodeHandle(k.user))
```

## Bodies

There is one body kind, addressed by `BodyHandle`. Mass decides the
role:

| Body | How |
|---|---|
| dynamic | `mass > 0`. Fully simulated |
| static | `mass = 0` (the default). Never moves |
| kinematic | a `mass = 0` body moved with `set_pose` / `set_velocity`. Moves by its velocity, pushes dynamic bodies, is never pushed back |
| sensor | `is_sensor = true`. Reports overlaps, never simulated or hit by queries |

```odin
h := physics.create_body(&w, pos, rot, collider, mass = 10, user = node)
s := physics.create_body(&w, pos, rot, collider, user = node) // static
t := physics.create_body(&w, pos, rot, collider, is_sensor = true)
physics.destroy_body(&w, h)
```

`get_body(&w, h)` returns a pointer to the `Body` (`ok = false` for a
stale handle). The solver, CCD, narrowphase and parallel stepping are
package-private.

## Colliders

`Collider` is a union of `SphereCollider`, `BoxCollider` and
`CylinderCollider` (axis = local Y). A dynamic body's inertia tensor
comes from its collider and mass.

## Moving and reshaping bodies

Plain fields are written through the body pointer: `restitution`,
`friction`, `linear_damping`, `angular_damping`. Anything that has to
keep derived state consistent goes through a setter; an invalid handle
is ignored.

| Proc | Effect |
|---|---|
| `set_pose(&w, h, position, rotation)` | teleport and wake; a static body becomes kinematic |
| `set_collider(&w, h, collider)` | reshape, reset inertia, wake |
| `set_mass(&w, h, mass)` | `> 0` makes the body dynamic, `0` freezes it as kinematic |
| `set_velocity(&w, h, v)` / `set_angular_velocity(&w, h, w)` | wake; a static body becomes kinematic |
| `apply_force(&w, h, f)` / `apply_impulse(&w, h, j)` | dynamic bodies only; wake |

Forces accumulate until the next `step` and are cleared after it.
Reads go through the body pointer (`body.position`, `body.rotation`,
`body.velocity`, `body.angular_velocity`). `body_poses(&w)` lists the
poses of awake moving bodies with a `user` link, for copying into the
scene graph after `step`.

## Queries

`raycast(&w, ray, max_dist, first_hit)` returns the closest hit (or
the first found with `first_hit = true`) as a `RayHit` with the body,
distance, point and surface normal. A ray that starts inside a shape
hits at `t = 0`. `overlap(&w, collider, position, rotation, &results)`
lists the bodies overlapping any collider shape, e.g. a
`SphereCollider` for an area-of-effect. Neither reports sensors.
