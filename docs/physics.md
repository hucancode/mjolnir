---
title: Physics
---

Layer 2. Rigid-body dynamics, collisions, spatial queries. Physics knows
nothing about the scene graph: the application owns a `physics.World`,
steps it in `update`, and copies `body_poses` back into world nodes
(see [glue](glue.html)). Every body and trigger carries a `user` handle
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

## Colliders

`Collider` is a union of `SphereCollider`, `BoxCollider`,
`CylinderCollider`, `FanCollider` (a cylinder wedge — useful for
cone-of-influence triggers). `create_dynamic_body` sets the body's
inertia tensor from its collider and mass; `set_inertia_from_collider`
recomputes it after the mass changes.

## Moving and reshaping bodies

`set_body_pose(&w, handle, position, rotation)` and
`set_body_collider(&w, handle, collider)` work on dynamic bodies,
static bodies and triggers. They keep the cached bounds and the BVH
consistent: static bodies refit the static BVH at once, dynamic bodies
wake up and are refit by the next `step`, and a new dynamic collider
also resets the inertia. Never write `position`, `rotation` or
`collider` on a body directly.

## Raycasts

`raycast`, `raycast_single` and `raycast_trigger` test the BVH
candidates exactly: boxes, cylinders and fans are tested in the
collider's local frame and return the true surface normal. A ray that
starts inside a shape hits at `t = 0`.

## Triggers

Triggers don't generate contact responses. They overlap-test only.
`trigger_overlaps` and `trigger_static_overlaps` are
populated each step for continuous-overlap events; on-demand
snapshots are available via `query_trigger*`.
