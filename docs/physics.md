---
title: Physics
---
# Physics Module (`mjolnir/physics`)

Rigid-body dynamics, collisions, and spatial queries.

The engine owns `engine.physics` (a `physics.World`). It is stepped and
synced to the scene graph every tick — you just spawn bodies and read
results. Tune `engine.physics.gravity` in `setup` for non-default gravity.

> User code should mostly use the engine-rooted shortcuts (`mjolnir.spawn_static`,
> `mjolnir.spawn_dynamic`, `mjolnir.create_dynamic_body`, etc.). See
> [`api_engine` §Shortcuts](api_engine.html#shortcuts) for the full list.

## Spawning a static body

```odin
import "../../mjolnir/physics"

setup :: proc(engine: ^mjolnir.Engine) {
  ground_mesh := mjolnir.builtin_mesh(engine, .CUBE)
  ground_mat  := mjolnir.builtin_material(engine, .GRAY)

  mjolnir.spawn_static(
    engine, {0, -0.5, 0},
    physics.BoxCollider{half_extents = {20, 0.5, 20}},
    ground_mesh, ground_mat,
    visual_scale = {20, 0.5, 20},
  )
}
```

`spawn_static` creates the node, the static body, and a scaled visual
child in one call.

## Spawning a dynamic body

```odin
node, body := mjolnir.spawn_dynamic(
  engine, {0, 10, 0}, mass = 50.0,
  physics.BoxCollider{half_extents = {0.5, 0.5, 0.5}},
  cube_mesh, cube_mat,
)
```

`spawn_dynamic` additionally calls `set_inertia_from_collider` so the
inertia tensor matches the collider variant (sphere / box / cylinder / fan).

Need raw bodies without a node attachment?

```odin
body := mjolnir.create_dynamic_body(
  engine,
  position = {0, 10, 0}, rotation = Q_IDENTITY,
  mass = 50, collider = physics.SphereCollider{radius = 1},
)
```

## Colliders

```odin
physics.SphereCollider{radius = 1.0}
physics.BoxCollider{half_extents = {0.5, 0.5, 0.5}}
physics.CylinderCollider{radius = 0.5, height = 2.0}
physics.FanCollider{radius = 6.0, height = 2.0, angle = math.PI * 0.5}
```

`Collider` is a union of these variants.

## Reading / mutating a body

```odin
if body, ok := mjolnir.get_dynamic_body(engine, handle); ok {
  body.friction        = 0.5     // 0 = frictionless, 1 = grippy
  body.restitution     = 0.3     // 0 = no bounce, 1 = perfect
  body.linear_damping  = 0.1
  body.angular_damping = 0.1
  body.velocity        = {0, 5, 0}
}
```

The engine writes `body.position` / `body.rotation` back to the node each
tick via `world.sync_all_physics_to_world`, so the scene graph follows.

## Forces & impulses

```odin
body, _ := mjolnir.get_dynamic_body(engine, handle)
physics.apply_force          (body, {0, 100, 0})        // wakes
physics.apply_impulse        (body, {0, 50, 0})         // wakes
physics.apply_force_at_point (body, force, point, center)
physics.apply_impulse_at_point(body, impulse, point)
```

## Inertia

The shortcut spawners set inertia automatically. For raw bodies use the
collider-dispatched helper:

```odin
physics.set_inertia_from_collider(body, body.collider)

// Or shape-specific:
physics.set_box_inertia      (body, {0.5, 0.5, 0.5})
physics.set_sphere_inertia   (body, 1.0)
physics.set_cylinder_inertia (body, radius = 0.5, height = 2.0)
```

Without it the inertia tensor stays at identity and rotations look
unrealistic.

## Spatial queries

```odin
// Raycast (all bodies)
hit := physics.raycast(
  &engine.physics,
  geometry.Ray{origin = {0, 10, 0}, direction = {0, -1, 0}},
  max_dist = 100.0,
)
if hit.hit do log.infof("hit %v at t=%.2f", hit.body_handle, hit.t)

// Sphere overlap → list of dynamic bodies
overlapping: [dynamic]physics.DynamicRigidBodyHandle
defer delete(overlapping)
physics.query_sphere(&engine.physics, center = {0, 0, 0}, radius = 5.0, results = &overlapping)

// Trigger overlap → triggers in a sphere
triggers: [dynamic]physics.TriggerHandle
defer delete(triggers)
physics.query_triggers_in_sphere(&engine.physics, center, radius, &triggers)
```

`hit.body_handle` is a union of `DynamicRigidBodyHandle` / `StaticRigidBodyHandle` /
`TriggerHandle` — switch on it to act accordingly. Triggers only:
`physics.raycast_trigger`.

## Triggers

Triggers don't generate contacts; they overlap-test only.

```odin
zone := physics.create_trigger(
  &engine.physics,
  position = {0, 1, 0},
  collider = physics.FanCollider{radius = 6.0, height = 2.0, angle = math.PI * 0.5},
)

// Per frame:
hits: [dynamic]physics.DynamicRigidBodyHandle
defer delete(hits)
physics.query_trigger(&engine.physics, zone, &hits)
```

`engine.physics.trigger_overlaps` is populated each step for continuous
overlap events.

## Fast-moving bodies

Fast bodies (bullets, projectiles) don't tunnel through thin walls — the
engine handles it for you. No extra setup required. See
[`examples/bullet_wall_ccd`](https://github.com/hucancode/mjolnir/blob/master/examples/bullet_wall_ccd/main.odin)
for the canonical case.

## Tunable constants

```odin
KILL_Y :: -50.0   // bodies below this go dead
```
