---
title: Physics
---

Layer 2. Rigid-body dynamics, collisions, spatial queries. Physics knows
nothing about the scene graph: the application owns a `physics.World`,
steps it in `update`, and copies `body_poses` back into world nodes
(see [engine](engine.html#wiring-modules)). Every body and trigger carries a `user` handle
for that link; bodies are destroyed explicitly, not with their node.

## Step layout

```
update sleep timers
cache previous contacts (for warmstart)
apply gravity
integrate velocities (forces, damping)
CCD pass (swept tests, clamp dt for tunneling-prone bodies)
rebuild a BVH if bodies were created (or, dynamic only, kill-count > threshold)

substep loop × NUM_SUBSTEPS:
  bvh_refit
  broadphase (BVH traversal → contact candidates)
  narrow-phase (test_box_box / sphere_cyl / …)
  prepare_contact (mass matrix, Baumgarte bias)
  warmstart from previous frame (first substep only)
  constraint solver × CONSTRAINT_SOLVER_ITERS
  stabilization × STABILIZATION_ITERS (bias-free)
  integrate positions + rotations
  update cached AABB

trigger overlap detection
mark bodies below KILL_Y dead (deferred removal next rebuild)
```

## Why this shape

- **BVH broadphase, not grid.** Dense and sparse scenes both work
  without tuning. Rebuilds are amortized: refit each substep, full
  rebuild only when enough bodies died that the tree is unbalanced.
- **CCD only when needed.** A swept test fires when a body's
  per-frame translation exceeds a fraction of its bounding sphere.
  Bullets and projectiles "just work" without tunneling; slow bodies
  pay nothing.
- **Warmstart + Baumgarte stabilization.** Re-use last frame's
  contact impulses so the solver starts close to convergence, then a
  bias-free stabilization pass cancels positional drift without
  injecting energy.
- **Deferred kills.** A body below `KILL_Y` is marked dead and only
  removed at the next BVH rebuild — keeps handle generations stable
  inside a single step.

## World

`init(&w, gravity, enable_parallel)` and `shutdown(&w)` own the world;
`teardown(&w)` destroys every body and trigger but keeps the world
ready for reuse. `step(&w, dt)` advances one frame in `NUM_SUBSTEPS`
substeps. `w.gravity` is read every step; setting `w.paused = true`
makes `step` a no-op. After each step
`w.last_perf` holds a `PerfFrame` of timings and counters, and
`w.dynamic_contacts` / `w.static_contacts` hold the frame's contact
manifolds (read-only, for debug drawing).

Bodies are addressed by `DynamicRigidBodyHandle`,
`StaticRigidBodyHandle` and `TriggerHandle`. `get_dynamic_body`,
`get_static_body` and `get_trigger` (overloaded as `get`) return a
pointer to the `DynamicRigidBody`, `StaticRigidBody` or `TriggerBody`
(`ok = false` for a stale handle). The solver, CCD, narrow phase and
parallel stepping are package-private.

## Colliders

`Collider` is a union of `SphereCollider`, `BoxCollider`,
`CylinderCollider`, `FanCollider` (a cylinder wedge — useful for
cone-of-influence triggers). `create_dynamic_body` sets the body's
inertia tensor from its collider and mass; `set_body_mass` recomputes
it from the collider at the new mass.

## Creating and destroying

```odin
h := physics.create_dynamic_body(&w, pos, rot, mass, collider, user = node)
s := physics.create_static_body(&w, pos, rot, collider, user = node)
t := physics.create_trigger(&w, pos, rot, collider, user = node)
physics.destroy_body(&w, h) // or destroy_trigger
```

## Moving and reshaping bodies

Plain fields are written through the body pointer:
`restitution`, `friction` (dynamic and static), `linear_damping`,
`angular_damping` (dynamic). Anything that has to keep derived state
consistent goes through a setter on a handle; an invalid handle is
ignored.

| Proc | Applies to |
|---|---|
| `set_body_pose(&w, h, position, rotation)` | dynamic, static, trigger |
| `set_body_collider(&w, h, collider)` | dynamic, static, trigger |
| `set_body_mass(&w, h, mass)` | dynamic |
| `set_velocity(&w, h, v)` / `set_angular_velocity(&w, h, w)` | dynamic |
| `apply_force(&w, h, f)` / `apply_impulse(&w, h, j)` | dynamic |

Pose and collider setters keep the cached bounds and the BVH
consistent: static bodies refit the static BVH at once, dynamic bodies
wake up and are refit by the next `step`, and a new dynamic collider
also resets the inertia. Velocity setters, forces and impulses wake the
body. Forces accumulate until the next `step` and are cleared after it.

Reads go through the body pointer (`body.position`, `body.rotation`,
`body.velocity`, `body.angular_velocity`). `body_poses(&w)`
lists the poses of awake dynamic bodies with a `user` link, for copying
into the scene graph after `step`.

## Raycasts

`raycast`, `raycast_single` and `raycast_trigger` test the BVH
candidates exactly: boxes, cylinders and fans are tested in the
collider's local frame and return the true surface normal. A ray that
starts inside a shape hits at `t = 0`.

## Triggers

Triggers don't generate contact responses. They overlap-test only.
`trigger_overlaps` and `trigger_static_overlaps` are
populated each step for continuous-overlap events; on-demand
snapshots are available via `query_trigger`, `query_trigger_static`
and `query_triggers_in_sphere`. `query_sphere` and `query_box` return
the dynamic bodies overlapping a volume.
