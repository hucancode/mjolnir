---
title: physics API
---
# `mjolnir/physics` — API Reference

Rigid-body simulation: bodies, colliders, triggers, raycasts, overlap
queries. The engine owns one `physics.World` at `engine.physics`. Step,
sleeping, collision response, and tunneling-resistance for fast bodies
are handled automatically — user code spawns bodies and reads results.

Most user code calls the engine-rooted shortcuts (`mjolnir.spawn_dynamic`,
`mjolnir.spawn_static`, `mjolnir.create_dynamic_body`, …) — see
[`api_engine` §Shortcuts](api_engine.html#shortcuts). The procs below
are the underlying API.

## Handles

```odin
DynamicRigidBodyHandle :: distinct cont.Handle
StaticRigidBodyHandle  :: distinct cont.Handle
TriggerHandle          :: distinct cont.Handle

BodyHandleResult :: union {
  DynamicRigidBodyHandle,
  StaticRigidBodyHandle,
  TriggerHandle,
}
```

`BodyHandleResult` is what raycasts return — switch on it to find which
kind of body was hit.

## Colliders

```odin
SphereCollider   :: struct { radius: f32 }
BoxCollider      :: struct { half_extents: [3]f32 }
CylinderCollider :: struct { radius, height: f32 }
FanCollider      :: struct { radius, height, angle: f32 }   // angle in radians

Collider :: union { SphereCollider, BoxCollider, CylinderCollider, FanCollider }
```

`FanCollider` is a wedge — a cylinder slice. Useful for cone-of-influence
triggers (radar zones, melee swings).

## Bodies

User-tunable fields on a dynamic body:

```odin
DynamicRigidBody :: struct {
  position:         [3]f32,
  rotation:         quaternion128,
  collider:         Collider,
  velocity:         [3]f32,
  angular_velocity: [3]f32,
  restitution:      f32,            // 0 = no bounce, 1 = perfect bounce
  friction:         f32,            // 0 = frictionless, 1 = grippy
  linear_damping:   f32,
  angular_damping:  f32,
  enable_rotation:  bool,
  is_sleeping:      bool,
  is_killed:        bool,
  // (additional internal state for the solver lives on this struct
  //  but should not be written by user code)
}

StaticRigidBody :: struct {
  position:    [3]f32,
  rotation:    quaternion128,
  collider:    Collider,
  restitution: f32,
  friction:    f32,
}

TriggerBody :: struct { position, rotation, collider /* RigidBody base */ }
```

The engine writes `position` / `rotation` back to the attached scene node
each tick. Setting them directly is fine for teleports — set
`velocity = {0,0,0}` after.

### Initializing and applying forces

```odin
rigid_body_init        (body, position={0,0,0}, rotation=Q_IDENTITY, mass=1, enable_rotation=true)
static_rigid_body_init (body, position={0,0,0}, rotation=Q_IDENTITY)

set_mass               (body, mass: f32)
set_inertia_from_collider(body, collider: Collider)   // matches sphere/box/cyl/fan
set_box_inertia        (body, half_extents: [3]f32)
set_sphere_inertia     (body, radius: f32)
set_cylinder_inertia   (body, radius, height: f32)

apply_force            (body, force: [3]f32)               // wakes
apply_force_at_point   (body, force, point, center: [3]f32) // wakes
apply_impulse          (body, impulse: [3]f32)             // wakes
apply_impulse_at_point (body, impulse, point: [3]f32)      // wakes

wake_up                (body)
```

`spawn_dynamic` calls `set_inertia_from_collider` for you — only call it
yourself when you build a body without the shortcut.

## World

```odin
World :: struct {
  gravity:           [3]f32,
  gravity_magnitude: f32,
  enable_parallel:   bool,
  thread_count:      int,
  // (internal pools, broadphase, contacts, trigger overlaps live here too)
}

TriggerOverlap       :: struct { trigger: TriggerHandle, body: DynamicRigidBodyHandle }
TriggerStaticOverlap :: struct { trigger: TriggerHandle, body: StaticRigidBodyHandle  }
```

```odin
init   (world, gravity = {0, -9.81, 0}, enable_parallel = true)
destroy(world)
step   (world, dt: f32)
```

`engine.run` already calls `step` each frame. Adjust `engine.physics.gravity`
inside `setup` for non-default gravity.

## Body creation

Generic — collider passed as a union value:

```odin
create_dynamic_body(world, position={0,0,0}, rotation=Q_IDENTITY, mass=1, collider: Collider={}) -> (DynamicRigidBodyHandle, bool)
create_static_body (world, position={0,0,0}, rotation=Q_IDENTITY, collider: Collider={})         -> (StaticRigidBodyHandle, bool)
```

Shape-specific shortcuts (each returns `(handle, ok)`):

```odin
create_dynamic_body_sphere   (world, radius=1, position={0,0,0}, rotation=Q_IDENTITY, mass=1)
create_static_body_sphere    (world, radius=1, position={0,0,0}, rotation=Q_IDENTITY)
create_dynamic_body_box      (world, half_extents, position={0,0,0}, rotation=Q_IDENTITY, mass=1)
create_static_body_box       (world, half_extents, position={0,0,0}, rotation=Q_IDENTITY)
create_dynamic_body_cylinder (world, radius, height, position={0,0,0}, rotation=Q_IDENTITY, mass=1)
create_static_body_cylinder  (world, radius, height, position={0,0,0}, rotation=Q_IDENTITY)
create_dynamic_body_fan      (world, radius, height, angle, position={0,0,0}, rotation=Q_IDENTITY, mass=1)
create_static_body_fan       (world, radius, height, angle, position={0,0,0}, rotation=Q_IDENTITY)

destroy_dynamic_body(world, handle)
destroy_static_body (world, handle)
destroy_body        (world, handle)   // overloaded
```

## Engine wrappers

```odin
mjolnir.create_static_body  (engine, position, rotation, collider) -> StaticRigidBodyHandle
mjolnir.create_dynamic_body (engine, position, rotation, mass, collider) -> DynamicRigidBodyHandle
mjolnir.get_dynamic_body    (engine, handle) -> (^DynamicRigidBody, bool)

// Spawn node + body + optional visual child + auto-inertia in one call.
mjolnir.spawn_static (engine, position, collider,
                      mesh = {}, material = {}, visual_scale = {1,1,1},
                      cast_shadow = true) -> NodeHandle
mjolnir.spawn_dynamic(engine, position, mass, collider,
                      mesh = {}, material = {}, visual_scale = {1,1,1},
                      cast_shadow = true) -> (NodeHandle, DynamicRigidBodyHandle)
```

## Body access

```odin
get_dynamic_body(world, handle) -> (^DynamicRigidBody, bool)
get_static_body (world, handle) -> (^StaticRigidBody, bool)
get_trigger     (world, handle) -> (^TriggerBody, bool)
get             (world, handle)                          // overloaded
```

## Triggers

Triggers don't push bodies; they only report overlap.

```odin
create_trigger          (world, position={0,0,0}, rotation=Q_IDENTITY, collider: Collider={}) -> (TriggerHandle, bool)
create_trigger_sphere   (world, radius=1, position={0,0,0}, rotation=Q_IDENTITY)
create_trigger_box      (world, half_extents, position={0,0,0}, rotation=Q_IDENTITY)
create_trigger_cylinder (world, radius, height, position={0,0,0}, rotation=Q_IDENTITY)
create_trigger_fan      (world, radius, height, angle, position={0,0,0}, rotation=Q_IDENTITY)
destroy_trigger         (world, handle)

set_trigger_position    (world, handle, position)
set_trigger_rotation    (world, handle, rotation: quaternion128)
set_trigger_transform   (world, handle, position, rotation)
```

`world.trigger_overlaps` and `world.trigger_static_overlaps` are populated
each step; iterate them for continuous overlap events, or call
`query_trigger` / `query_trigger_static` for an on-demand snapshot.

## Spatial queries

```odin
RayHit :: struct {
  body_handle: BodyHandleResult,
  t:           f32,
  point:       [3]f32,
  normal:      [3]f32,
  hit:         bool,
}

raycast        (world, ray, max_dist = max(f32)) -> RayHit   // all bodies
raycast_single (world, ray, max_dist = max(f32)) -> RayHit   // first hit, faster
raycast_trigger(world, ray, max_dist = max(f32)) -> RayHit   // triggers only

query_sphere     (world, center, radius, results: ^[dynamic]DynamicRigidBodyHandle)
query_box        (world, bounds: geometry.Aabb, results: ^[dynamic]DynamicRigidBodyHandle)
query_trigger    (world, handle: TriggerHandle, results: ^[dynamic]DynamicRigidBodyHandle)
query_trigger_static    (world, handle, results: ^[dynamic]StaticRigidBodyHandle)
query_triggers_in_sphere(world, center, radius, results: ^[dynamic]TriggerHandle)

test_collider_sphere_overlap(collider, pos, rot, sphere_center, sphere_radius) -> bool
test_collider_aabb_overlap  (collider, pos, rot, bounds: geometry.Aabb) -> bool
```

Switch on `hit.body_handle` to dispatch on body kind:

```odin
hit := mjolnir.raycast(engine, geometry.Ray{origin = cam_pos, direction = forward})
switch h in hit.body_handle {
case physics.DynamicRigidBodyHandle: ...
case physics.StaticRigidBodyHandle:  ...
case physics.TriggerHandle:          ...
}
```

## Pairwise collision tests

Building blocks for custom queries — each returns
`(point, normal, penetration, hit)`:

```odin
test_sphere_sphere    (pos_a, sphere_a, pos_b, sphere_b)
test_box_box          (pos_a, rot_a, box_a, pos_b, rot_b, box_b)
test_box_sphere       (pos_box, rot_box, box, pos_sphere, sphere, invert_normal=false)
test_sphere_cylinder  (pos_sphere, sphere, pos_cyl, rot_cyl, cyl, invert_normal=false)
test_box_cylinder     (pos_box, rot_box, box, pos_cyl, rot_cyl, cyl, invert_normal=false)
test_cylinder_cylinder(pos_a, rot_a, cyl_a, pos_b, rot_b, cyl_b)
test_point_cylinder   (point, cyl_center, cyl_rot, cyl) -> bool
test_point_fan        (point, fan_center, fan_rot, fan) -> bool

test_collision_collider_collider(collider_a, pos_a, rot_a, collider_b, pos_b, rot_b)
test_collision                  (overloaded for handle types)
```

## Fast-moving bodies

Bullets, projectiles, and other fast bodies don't tunnel through thin
walls — the engine have CCD handled when velocity exceeds the per-frame threshold. 
[`examples/bullet_wall_ccd`](https://github.com/hucancode/mjolnir/blob/master/examples/bullet_wall_ccd/main.odin).

## Tunable constants

```odin
KILL_Y                  :: f32(-50.0)   // bodies below this go dead
SEA_LEVEL_AIR_DENSITY   :: 1.225
SLEEP_LINEAR_THRESHOLD  :: 0.05
SLEEP_ANGULAR_THRESHOLD :: 0.05
SLEEP_TIME_THRESHOLD    :: 0.5
```

The remaining constants (substep count, solver iterations, BVH thresholds,
warmstart and Baumgarte coefficients) are internal solver tuning — not
expected to be touched. Read `physics/solver.odin` if you need them.
