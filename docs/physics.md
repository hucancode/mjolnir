---
title: Physics
---

Rigid-body dynamics, collisions, spatial queries. The engine owns one
`physics.World` at `engine.physics` and steps it each tick before
syncing transforms back into the scene graph.

## Step layout

```
update sleep timers
cache previous contacts (for warmstart)
apply gravity
integrate velocities (forces, damping)
CCD pass (swept tests, clamp dt for tunneling-prone bodies)
rebuild dynamic + static BVH if kill-count > threshold

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
cone-of-influence triggers). Each collider has a matching inertia
helper that `spawn_dynamic` calls automatically.

## Triggers

Triggers don't generate contact responses. They overlap-test only.
`engine.physics.trigger_overlaps` and `trigger_static_overlaps` are
populated each step for continuous-overlap events; on-demand
snapshots are available via `query_trigger*`.
