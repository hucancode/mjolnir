# Physics Module (`mjolnir/physics`)

The Physics module provides rigid body dynamics, collision detection, spatial queries, and continuous collision detection (CCD).

## Initialization

```odin
import "../../mjolnir/physics"

physics_world: physics.World

setup :: proc(engine: ^mjolnir.Engine) {
  // Initialize with gravity
  physics.init(&physics_world, gravity = {0, -10, 0})
}
```

## Static Bodies

Static bodies don't move - used for ground, walls, obstacles.

```odin
// Create static box
physics.create_static_body_box(
  &physics_world,
  half_extents = {10, 0.5, 10},
  position = {0, -0.5, 0},
  rotation = {},
)

// Create static sphere
physics.create_static_body_sphere(
  &physics_world,
  radius = 3.0,
  position = {5, 3, 0},
  rotation = {},
)

// Create static cylinder
physics.create_static_body_cylinder(
  &physics_world,
  radius = 1.0,
  half_height = 2.0,
  position = {0, 2, 0},
  rotation = {},
)
```

## Dynamic Bodies

Dynamic bodies respond to forces and collisions.

```odin
// Create dynamic box
body_handle := physics.create_dynamic_body_box(
  &physics_world,
  half_extents = {0.5, 0.5, 0.5},
  position = {0, 10, 0},
  rotation = {},
  mass = 50.0,
)

// Set inertia for box
if body, ok := physics.get_dynamic_body(&physics_world, body_handle); ok {
  physics.set_box_inertia(body, {0.5, 0.5, 0.5})
}

// Create dynamic sphere
sphere_handle := physics.create_dynamic_body_sphere(
  &physics_world,
  radius = 1.0,
  position = {0, 5, 0},
  rotation = {},
  mass = 50.0,
)

if body, ok := physics.get_dynamic_body(&physics_world, sphere_handle); ok {
  physics.set_sphere_inertia(body, radius = 1.0)
}

// Create dynamic cylinder
cylinder_handle := physics.create_dynamic_body_cylinder(
  &physics_world,
  radius = 0.5,
  half_height = 1.0,
  position = {0, 8, 0},
  rotation = {},
  mass = 50.0,
)

if body, ok := physics.get_dynamic_body(&physics_world, cylinder_handle); ok {
  physics.set_cylinder_inertia(body, radius = 0.5, height = 2.0)
}
```

## Attaching Physics to World Nodes

```odin
// Create world node for visual representation
physics_node := world.spawn(&engine.world, {0, 10, 0}) or_else {}
physics_node_ptr := world.get_node(&engine.world, physics_node)

// Create physics body at same position
body_handle := physics.create_dynamic_body_box(
  &physics_world,
  {0.5, 0.5, 0.5},
  physics_node_ptr.transform.position,
  physics_node_ptr.transform.rotation,
  50.0,
)

// Attach physics handle to node
physics_node_ptr.attachment = world.RigidBodyAttachment{
  body_handle = body_handle,
}

// Create child node with visual mesh
mesh_node := world.spawn_child(
  &engine.world,
  physics_node,
  attachment = world.MeshAttachment{
    handle = cube_mesh,
    material = cube_material,
    cast_shadow = true,
  },
) or_else {}
```

## Simulation

```odin
update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Step physics simulation
  physics.step(&physics_world, delta_time)
  
  // Sync physics results back to world nodes
  world.sync_all_physics_to_world(&engine.world, &physics_world)
}
```

## Forces and Velocities

```odin
// Get body reference
body, ok := physics.get_dynamic_body(&physics_world, body_handle)
if !ok do return

// Apply force
force := [3]f32{0, 100, 0}
physics.apply_force(body, force)

// Set velocity directly
body.linear_velocity = {0, 5, 0}
body.angular_velocity = {0, 1, 0}

// Set position/rotation directly
body.position = {0, 10, 0}
body.rotation = linalg.quaternion_angle_axis_f32(math.PI * 0.5, {0, 1, 0})
```

## Collision Detection

```odin
// Collisions are detected automatically during physics.step()
// Access collision pairs after step:
for pair in physics_world.collision_pairs {
  log.infof("Collision: %v <-> %v", pair.body_a, pair.body_b)
}
```

## Spatial Queries

```odin
// Raycast
hit, ok := physics.raycast(
  &physics_world,
  origin = {0, 10, 0},
  direction = {0, -1, 0},
  max_distance = 100.0,
)

if ok {
  log.infof("Hit at: %v", hit.position)
  log.infof("Normal: %v", hit.normal)
  log.infof("Distance: %f", hit.distance)
}

// Sphere cast
sphere_hit, ok := physics.sphere_cast(
  &physics_world,
  origin = {0, 10, 0},
  radius = 1.0,
  direction = {0, -1, 0},
  max_distance = 100.0,
)

// Overlap tests
overlapping := physics.sphere_overlap(
  &physics_world,
  center = {0, 0, 0},
  radius = 5.0,
)

for body in overlapping {
  log.infof("Body overlapping sphere: %v", body)
}
```

## Material Properties

```odin
// Set friction and restitution
if body, ok := physics.get_dynamic_body(&physics_world, body_handle); ok {
  body.friction = 0.5      // 0 = frictionless, 1 = high friction
  body.restitution = 0.3   // 0 = no bounce, 1 = perfect bounce
}
```

## Continuous Collision Detection (CCD)

For fast-moving objects that might tunnel through geometry:

```odin
if body, ok := physics.get_dynamic_body(&physics_world, body_handle); ok {
  body.use_ccd = true
}
```
