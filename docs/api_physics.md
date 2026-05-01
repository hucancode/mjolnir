# `mjolnir/physics` — API Reference

Layer 2. Constraint-solver rigid-body simulation with BVH broadphase, SIMD
contact resolution, and continuous collision detection (CCD). See
[architecture §10](architecture.html#10-physics-step-model) for the step
pipeline.

## Constants

```odin
KILL_Y                       :: f32(-50.0)   // bodies below this go dead
SEA_LEVEL_AIR_DENSITY        :: 1.225
NUM_SUBSTEPS                 :: i32(2)
CONSTRAINT_SOLVER_ITERS      :: i32(4)
STABILIZATION_ITERS          :: i32(2)
SLEEP_LINEAR_THRESHOLD       :: 0.05
SLEEP_ANGULAR_THRESHOLD      :: 0.05
SLEEP_TIME_THRESHOLD         :: 0.5
ENABLE_VERBOSE_LOG           :: false
BVH_REBUILD_THRESHOLD        :: i32(512)
BROADPHASE_BVH_TRAVERSAL     :: true

// ccd.odin
CCD_THRESHOLD                :: 5.0          // velocity to trigger swept tests

// parallel.odin
DEFAULT_THREAD_COUNT         :: i32(16)
WARMSTART_COEF               :: 0.8

// solver.odin
BAUMGARTE_COEF               :: 0.4
SLOP                         :: 0.002
RESTITUTION_THRESHOLD        :: f32(-0.5)
```

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

## Colliders

```odin
ColliderType :: enum { Sphere, Box, Capsule, Cylinder, Fan }

SphereCollider   :: struct { radius: f32 }
BoxCollider      :: struct { half_extents: [3]f32 }
CylinderCollider :: struct { radius, height: f32 }
FanCollider      :: struct { radius, height, angle: f32 }   // angle in radians

Collider :: union { SphereCollider, BoxCollider, CylinderCollider, FanCollider }

collider_calculate_aabb(self: ^Collider, position, rotation: quaternion128) -> geometry.Aabb
collider_min_extent    (self: ^Collider) -> f32
```

(Capsule appears in `ColliderType` but the union currently only carries
sphere/box/cylinder/fan variants. Capsule support comes through cylinder +
hemisphere.)

## Bodies

```odin
RigidBody :: struct {
  position:             [3]f32,
  cached_sphere_radius: f32,
  rotation:             quaternion128,
  collider:             Collider,
  cached_aabb:          geometry.Aabb,
  cached_sphere_center: [3]f32,
}

TriggerBody :: struct { using base: RigidBody }

StaticRigidBody :: struct {
  using base:   RigidBody,
  restitution:  f32,
  friction:     f32,
}

DynamicRigidBody :: struct {
  using body:       StaticRigidBody,
  enable_rotation:  bool,
  is_sleeping:      bool,
  inv_inertia:      [3]f32,        // diagonal of inertia^-1
  mass:             f32,
  velocity:         [3]f32,
  inv_mass:         f32,
  angular_velocity: [3]f32,
  linear_damping:   f32,
  force:            [3]f32,
  angular_damping:  f32,
  torque:           [3]f32,
  sleep_timer:      f32,
  is_killed:        bool,
}
```

```odin
rigid_body_init       (body, position={0,0,0}, rotation=Q_IDENTITY, mass=1, enable_rotation=true)
static_rigid_body_init(body, position={0,0,0}, rotation=Q_IDENTITY)
wake_up               (body)                              // inline
set_mass              (body, mass: f32)
set_box_inertia       (body, half_extents: [3]f32)
set_sphere_inertia    (body, radius: f32)
set_cylinder_inertia  (body, radius: f32, height: f32)
apply_force           (body, force: [3]f32)               // wakes
apply_force_at_point  (body, force, point, center: [3]f32) // wakes
apply_impulse         (body, impulse: [3]f32)             // wakes
apply_impulse_at_point(body, impulse, point: [3]f32)      // inline, wakes
integrate             (body, dt: f32)
clear_forces          (body)
update_cached_aabb    (body: ^RigidBody)
```

## Contacts

```odin
DynamicContact :: struct {
  body_a, body_b:      DynamicRigidBodyHandle,
  point, normal:       [3]f32,
  penetration:         f32,
  restitution, friction: f32,
  normal_impulse:      f32,
  tangent_impulse:     [2]f32,
  normal_mass:         f32,
  tangent_mass:        [2]f32,
  bias:                f32,
  r_a, r_b:            [3]f32,
  tangent1, tangent2:  [3]f32,
}

StaticContact :: struct {                // dynamic-static contact
  body_a:               DynamicRigidBodyHandle,
  body_b:               StaticRigidBodyHandle,
  // ... same as DynamicContact except body_b is static
}
```

## World

```odin
TriggerOverlap         :: struct { trigger: TriggerHandle, body: DynamicRigidBodyHandle }
TriggerStaticOverlap   :: struct { trigger: TriggerHandle, body: StaticRigidBodyHandle  }
DynamicBroadPhaseEntry :: struct { handle: DynamicRigidBodyHandle, bounds: geometry.Aabb }
StaticBroadPhaseEntry  :: struct { handle: StaticRigidBodyHandle,  bounds: geometry.Aabb }

World :: struct {
  bodies:                   PoolSoA(DynamicRigidBody),
  static_bodies:            PoolSoA(StaticRigidBody),
  dynamic_contacts:         [dynamic]DynamicContact,
  static_contacts:          [dynamic]StaticContact,
  prev_dynamic_contacts:    map[u64]DynamicContact,
  prev_static_contacts:     map[u64]StaticContact,
  trigger_overlaps:         [dynamic]TriggerOverlap,
  trigger_static_overlaps:  [dynamic]TriggerStaticOverlap,
  gravity:                  [3]f32,
  gravity_magnitude:        f32,
  dynamic_bvh:              BVH(DynamicBroadPhaseEntry),
  static_bvh:               BVH(StaticBroadPhaseEntry),
  body_bounds:              [dynamic]geometry.Aabb,
  trigger_bodies:           PoolSoA(TriggerBody),
  enable_parallel:          bool,
  thread_count:             int,
  thread_pool:              thread.Pool,
  killed_body_count:        int,
  last_dynamic_count:        int,
  last_static_count:         int,
}
```

```odin
init   (world, gravity = {0, -9.81, 0}, enable_parallel = true)
destroy(world)
step   (world, dt: f32)
```

## Body creation (overloaded)

Generic:

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

## Body access

```odin
get_dynamic_body(world, handle) -> (^DynamicRigidBody, bool)
get_static_body (world, handle) -> (^StaticRigidBody, bool)
get_trigger     (world, handle) -> (^TriggerBody, bool)
get             (world, handle)                          // overloaded
```

## Triggers

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

## Collision tests

Bounding-volume helpers:

```odin
bounding_spheres_intersect(pos_a, radius_a, pos_b, radius_b) -> bool
```

Pairwise tests — each returns `(point, normal, penetration, hit)`:

```odin
test_sphere_sphere   (pos_a, sphere_a, pos_b, sphere_b)
test_box_box         (pos_a, rot_a, box_a, pos_b, rot_b, box_b)
test_box_sphere      (pos_box, rot_box, box, pos_sphere, sphere, invert_normal=false)
test_sphere_cylinder (pos_sphere, sphere, pos_cyl, rot_cyl, cyl, invert_normal=false)
test_box_cylinder    (pos_box, rot_box, box, pos_cyl, rot_cyl, cyl, invert_normal=false)
test_cylinder_cylinder(pos_a, rot_a, cyl_a, pos_b, rot_b, cyl_b)
test_point_cylinder  (point, cyl_center, cyl_rot, cyl) -> bool
test_point_fan       (point, fan_center, fan_rot, fan) -> bool

test_collision_collider_collider(collider_a, pos_a, rot_a, collider_b, pos_b, rot_b)
test_collision                  (overloaded for handle types)

collision_pair_hash_dynamic(a: DynamicRigidBodyHandle, b: DynamicRigidBodyHandle) -> u64
collision_pair_hash_static (a: DynamicRigidBodyHandle, b: StaticRigidBodyHandle)  -> u64
collision_pair_hash        (overloaded)
```

## CCD

```odin
TOIResult :: struct {
  has_impact: bool,
  time:       f32,         // 0..1 fraction of motion
  normal:     [3]f32,
  point:      [3]f32,
}

swept_sphere_sphere(pos_a, pos_b, radius_a, radius_b, velocity_a) -> TOIResult
swept_sphere_box   (center, radius, velocity, box_min, box_max)   -> TOIResult
swept_box_box      (pos_a, pos_b, half_extents_a, half_extents_b, velocity_a) -> TOIResult
swept_test         (collider_a, collider_b, pos_a, pos_b, rot_a, rot_b, velocity_a) -> TOIResult
```

## Constraint solver

```odin
prepare_contact_dynamic_dynamic(contact, body_a, body_b, dt: f32)
prepare_contact_dynamic_static (contact, body_a, body_b, dt: f32)
prepare_contact                (overloaded)

warmstart_contact_dynamic_dynamic(contact, body_a, body_b)
warmstart_contact_dynamic_static (contact, body_a, body_b)
warmstart_contact                (overloaded)

resolve_contact_dynamic_dynamic        (contact, body_a, body_b)
resolve_contact_dynamic_static         (contact, body_a, body_b)
resolve_contact_batch4_dynamic_dynamic (contacts: [4], bodies_a, bodies_b: [4])  // SIMD
resolve_contact                        (overloaded, with bias)

resolve_contact_no_bias_dynamic_dynamic        (contact, body_a, body_b)
resolve_contact_no_bias_dynamic_static         (contact, body_a, body_b)
resolve_contact_batch4_no_bias_dynamic_dynamic (contacts, bodies_a, bodies_b)
resolve_contact_no_bias                        (overloaded, no bias — stabilization)

compute_tangent_basis(normal: [3]f32) -> ([3]f32, [3]f32)
```

## Spatial queries

```odin
RayHit :: struct {
  body_handle: BodyHandleResult,
  t:           f32,
  point:       [3]f32,
  normal:      [3]f32,
  hit:         bool,
}

raycast        (world, ray, max_dist = max(f32)) -> RayHit
raycast_single (world, ray, max_dist = max(f32)) -> RayHit
raycast_trigger(world, ray, max_dist = max(f32)) -> RayHit

raycast_collider(ray, collider, position, rotation, max_dist) -> (t: f32, normal: [3]f32, hit: bool)

query_sphere     (world, center, radius, results: ^[dynamic]DynamicRigidBodyHandle)
query_box        (world, bounds: geometry.Aabb, results: ^[dynamic]DynamicRigidBodyHandle)
query_trigger    (world, handle: TriggerHandle, results: ^[dynamic]DynamicRigidBodyHandle)
query_trigger_static(world, handle, results: ^[dynamic]StaticRigidBodyHandle)
query_triggers_in_sphere(world, center, radius, results: ^[dynamic]TriggerHandle)

test_collider_sphere_overlap(collider, pos, rot, sphere_center, sphere_radius) -> bool
test_collider_aabb_overlap  (collider, pos, rot, bounds: geometry.Aabb) -> bool
```

## Integration helpers

```odin
apply_gravity        (world)
integrate_velocities (world, dt: f32)
integrate_positions  (world, dt: f32, ccd_handled: []bool)
integrate_rotations  (world, dt: f32, ccd_handled: []bool)
```

## SIMD batch ops

Re-exports from `geometry`:

```odin
aabb_intersects_batch4
obb_to_aabb_batch4
vector_cross3_batch4
quaternion_mul_vector3_batch4
vector_dot3_batch4
vector_length3_batch4
vector_normalize3_batch4
```
