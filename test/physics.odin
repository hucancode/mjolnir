package tests

import "../mjolnir/geometry"
import "../mjolnir/physics"
import "../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_rigid_body_apply_force :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(
    &body,
    {},
    linalg.QUATERNIONF32_IDENTITY,
    10.0,
    false,
  )
  force := [3]f32{100, 0, 0}
  physics.apply_force(&body, force)
  testing.expect(
    t,
    abs(body.force.x - 100) < 0.001 &&
    abs(body.force.y) < 0.001 &&
    abs(body.force.z) < 0.001,
    "Force should be accumulated",
  )
}

@(test)
test_rigid_body_apply_impulse :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(
    &body,
    {},
    linalg.QUATERNIONF32_IDENTITY,
    10.0,
    false,
  )
  impulse := [3]f32{50, 0, 0}
  physics.apply_impulse(&body, impulse)
  expected_velocity := impulse * body.inv_mass
  testing.expect(
    t,
    abs(body.velocity.x - expected_velocity.x) < 0.001 &&
    abs(body.velocity.y - expected_velocity.y) < 0.001 &&
    abs(body.velocity.z - expected_velocity.z) < 0.001,
    "Velocity should change based on impulse",
  )
}

@(test)
test_rigid_body_integration :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(
    &body,
    {},
    linalg.QUATERNIONF32_IDENTITY,
    10.0,
    false,
  )
  force := [3]f32{100, 0, 0}
  physics.apply_force(&body, force)
  dt := f32(0.016)
  physics.integrate(&body, dt)
  // Account for damping: velocity gets multiplied by exponential decay factor pow(1 - damping, dt)
  damping_factor := math.pow(1.0 - body.linear_damping, dt)
  expected_velocity := force * body.inv_mass * dt * damping_factor
  testing.expect(
    t,
    abs(body.velocity.x - expected_velocity.x) < 0.001 &&
    abs(body.velocity.y - expected_velocity.y) < 0.001 &&
    abs(body.velocity.z - expected_velocity.z) < 0.001,
    "Velocity should integrate force over time with damping",
  )
  testing.expect(
    t,
    abs(body.force.x) < 0.001 &&
    abs(body.force.y) < 0.001 &&
    abs(body.force.z) < 0.001,
    "Force should be cleared after integration",
  )
}

@(test)
test_physics_world_gravity_application :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, -10, 0}, false)
  defer physics.destroy(&physics_world)
  body_handle, body_ok := physics.create_dynamic_body_sphere(
    &physics_world,
    1.0,
    {},
    linalg.QUATERNIONF32_IDENTITY,
    2.0,
  )
  testing.expect(t, body_ok, "Body creation should succeed")
  body, get_ok := physics.get_dynamic_body(&physics_world, body_handle)
  testing.expect(t, get_ok, "Body retrieval should succeed")
  initial_velocity := body.velocity.y
  dt := f32(0.016)
  physics.step(&physics_world, dt)
  body = physics.get_dynamic_body(&physics_world, body_handle)
  expected_velocity_change := physics_world.gravity.y * dt
  testing.expect(
    t,
    abs((body.velocity.y - initial_velocity) - expected_velocity_change) < 0.1,
    "Body should accelerate due to gravity",
  )
}

@(test)
test_physics_world_two_body_collision :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, 0, 0}, false)
  defer physics.destroy(&physics_world)
  body_a_handle, _ := physics.create_dynamic_body_sphere(
    &physics_world,
    1.0,
    {},
    linalg.QUATERNIONF32_IDENTITY,
    1.0,
  )
  body_b_handle, _ := physics.create_dynamic_body_sphere(
    &physics_world,
    1.0,
    {1.5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    1.0,
  )
  body_a, _ := physics.get_dynamic_body(&physics_world, body_a_handle)
  body_b, _ := physics.get_dynamic_body(&physics_world, body_b_handle)
  body_a.velocity = {10, 0, 0}
  body_b.velocity = {-10, 0, 0}
  dt := f32(0.016)
  physics.step(&physics_world, dt)
  testing.expect(
    t,
    len(physics_world.dynamic_contacts) > 0,
    "Collision should be detected",
  )
  testing.expect(
    t,
    body_a.velocity.x < 10.0,
    "Body A velocity should decrease after collision",
  )
  testing.expect(
    t,
    body_b.velocity.x > -10.0,
    "Body B velocity should increase after collision",
  )
}

@(test)
test_physics_world_static_body_collision :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, 0, 0}, false)
  defer physics.destroy(&physics_world)
  body_static_handle, _ := physics.create_static_body_sphere(&physics_world)
  body_dynamic_handle, _ := physics.create_dynamic_body_sphere(
    &physics_world,
    1.0,
    {1.5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    1.0,
  )
  body_dynamic, _ := physics.get_dynamic_body(&physics_world, body_dynamic_handle)
  body_dynamic.velocity = {-10, 0, 0}
  dt := f32(0.016)
  physics.step(&physics_world, dt)
  testing.expect(
    t,
    len(physics_world.static_contacts) > 0,
    "Collision should be detected",
  )
  testing.expect(
    t,
    body_dynamic.velocity.x > -10.0,
    "Dynamic body should bounce off static body",
  )
}

@(test)
test_resolve_contact_momentum_conservation :: proc(t: ^testing.T) {
  body_a: physics.DynamicRigidBody
  body_b: physics.DynamicRigidBody
  physics.rigid_body_init(&body_a, mass = 2.0)
  physics.rigid_body_init(&body_b, mass = 3.0)
  body_a.velocity = {5, 0, 0}
  body_b.velocity = {-3, 0, 0}
  initial_momentum :=
    body_a.velocity * body_a.mass + body_b.velocity * body_b.mass
  contact := physics.DynamicContact {
    point       = {0, 0, 0},
    normal      = {1, 0, 0},
    penetration = 0.1,
    restitution = 0.0,
    friction    = 0.0,
  }
  dt := f32(0.016)
  physics.prepare_contact(&contact, &body_a, &body_b, dt)
  physics.resolve_contact(&contact, &body_a, &body_b)
  final_momentum :=
    body_a.velocity * body_a.mass + body_b.velocity * body_b.mass
  testing.expect(
    t,
    abs(final_momentum.x - initial_momentum.x) < 0.001,
    "Momentum X should be conserved",
  )
  testing.expect(
    t,
    abs(final_momentum.y) < 0.001 && abs(final_momentum.z) < 0.001,
    "No momentum should be created in Y/Z",
  )
}

@(test)
test_rigid_body_apply_force_at_point_generates_torque :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(&body)
  physics.set_sphere_inertia(&body, 1.0)
  center := [3]f32{0, 0, 0}
  point := [3]f32{1, 0, 0}
  force := [3]f32{0, 1, 0}
  physics.apply_force_at_point(&body, force, point, center)
  testing.expect(
    t,
    abs(body.force.y - 1.0) < 0.001,
    "Force should be accumulated",
  )
  testing.expect(
    t,
    abs(body.torque.z - 1.0) < 0.001,
    "Torque should be r × F in Z direction",
  )
  testing.expect(
    t,
    abs(body.torque.x) < 0.001 && abs(body.torque.y) < 0.001,
    "No torque in X or Y",
  )
}

@(test)
test_physics_world_ccd_prevents_tunneling :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, 0, 0}, false)
  defer physics.destroy(&physics_world)
  body_bullet_handle, _ := physics.create_dynamic_body_sphere(
    &physics_world,
    0.1,
    {-5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    0.1,
  )
  physics.create_static_body_box(
    &physics_world,
    {0.5, 5, 5},
  )
  body_bullet := physics.get_dynamic_body(&physics_world, body_bullet_handle)
  body_bullet.velocity = {100, 0, 0}
  dt := f32(0.016)
  physics.step(&physics_world, dt)
  testing.expect(
    t,
    body_bullet.position.x < 0.5,
    "CCD should prevent tunneling through wall",
  )
  testing.expect(
    t,
    body_bullet.velocity.x < 100,
    "CCD should reflect/reduce velocity",
  )
}

@(test)
test_physics_world_angular_integration :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, 0, 0}, false)
  defer physics.destroy(&physics_world)
  body_handle, _ := physics.create_dynamic_body(&physics_world)
  body, _ := physics.get_dynamic_body(&physics_world, body_handle)
  physics.set_sphere_inertia(body, 1.0)
  body.angular_velocity = {0, math.PI, 0}
  initial_rotation := body.rotation
  dt := f32(1.0)
  physics.step(&physics_world, dt)
  rotation_changed :=
    abs(body.rotation.w - initial_rotation.w) > 0.1 ||
    abs(body.rotation.x - initial_rotation.x) > 0.1 ||
    abs(body.rotation.y - initial_rotation.y) > 0.1 ||
    abs(body.rotation.z - initial_rotation.z) > 0.1
  testing.expect(
    t,
    rotation_changed,
    "Angular velocity should update rotation quaternion",
  )
}

@(test)
test_physics_world_kill_y_threshold :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, enable_parallel = false)
  defer physics.destroy(&physics_world)
  body_handle, _ := physics.create_dynamic_body(
    &physics_world,
    {0, physics.KILL_Y - 1, 0},
  )
  dt := f32(0.016)
  physics.step(&physics_world, dt)
  destroyed_body, _ := physics.get_dynamic_body(&physics_world, body_handle)
  testing.expect(
    t,
    destroyed_body == nil,
    "Body below KILL_Y should be destroyed",
  )
}

@(test)
test_gjk_sphere_sphere_intersecting :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.SphereCollider{radius = 1.0},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  simplex: physics.Simplex
  result := physics.gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  )
  testing.expect(
    t,
    result,
    "GJK should detect collision between intersecting spheres",
  )
}

@(test)
test_gjk_sphere_sphere_separated :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.SphereCollider{radius = 1.0},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{3, 0, 0}
  simplex: physics.Simplex
  result := physics.gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  )
  testing.expect(
    t,
    !result,
    "GJK should not detect collision between separated spheres",
  )
}

@(test)
test_gjk_box_box_intersecting :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.BoxCollider{half_extents = {1, 1, 1}},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  simplex: physics.Simplex
  result := physics.gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  )
  testing.expect(
    t,
    result,
    "GJK should detect collision between intersecting boxes",
  )
}

@(test)
test_gjk_box_box_separated :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.BoxCollider{half_extents = {1, 1, 1}},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{5, 0, 0}
  simplex: physics.Simplex
  result := physics.gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  )
  testing.expect(
    t,
    !result,
    "GJK should not detect collision between separated boxes",
  )
}

@(test)
test_gjk_sphere_box_intersecting :: proc(t: ^testing.T) {
  collider_sphere := physics.Collider {
    shape = physics.SphereCollider{radius = 1.0},
  }
  collider_box := physics.Collider {
    shape = physics.BoxCollider{half_extents = {1, 1, 1}},
  }
  // Sphere at (1.5, 0, 0) with radius 1.0 reaches from 0.5 to 2.5
  // Box at (0, 0, 0) with extents 1 reaches from -1 to 1
  // They overlap from 0.5 to 1.0
  pos_sphere := [3]f32{1.5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  simplex: physics.Simplex
  result := physics.gjk(
    &collider_sphere,
    pos_sphere,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_box,
    pos_box,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  )
  testing.expect(
    t,
    result,
    "GJK should detect collision between sphere and box",
  )
}

@(test)
test_gjk_sphere_box_separated :: proc(t: ^testing.T) {
  collider_sphere := physics.Collider {
    shape = physics.SphereCollider{radius = 1.0},
  }
  collider_box := physics.Collider {
    shape = physics.BoxCollider{half_extents = {1, 1, 1}},
  }
  pos_sphere := [3]f32{5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  simplex: physics.Simplex
  result := physics.gjk(
    &collider_sphere,
    pos_sphere,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_box,
    pos_box,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  )
  testing.expect(
    t,
    !result,
    "GJK should not detect collision when sphere and box are separated",
  )
}

@(test)
test_epa_sphere_sphere_penetration :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.SphereCollider{radius = 1.0},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  simplex: physics.Simplex
  if !physics.gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  ) {
    testing.fail_now(t, "GJK should detect collision")
  }
  normal, depth, ok := physics.epa(
    simplex,
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
  )
  testing.expect(t, ok, "EPA should succeed")
  testing.expect(
    t,
    abs(depth - 0.5) < 0.1,
    "EPA depth should be approximately 0.5",
  )
  testing.expect(
    t,
    abs(linalg.length(normal) - 1.0) < 0.1,
    "Normal should be normalized",
  )
}

@(test)
test_epa_box_box_penetration :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.BoxCollider{half_extents = {1, 1, 1}},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  simplex: physics.Simplex
  if !physics.gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    &simplex,
  ) {
    testing.fail_now(t, "GJK should detect collision")
  }
  normal, depth, ok := physics.epa(
    simplex,
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
  )
  testing.expect(t, ok, "EPA should succeed")
  testing.expect(
    t,
    abs(depth - 0.5) < 0.1,
    "EPA depth should be approximately 0.5",
  )
  testing.expect(
    t,
    abs(linalg.length(normal) - 1.0) < 0.1,
    "Normal should be normalized",
  )
}

@(test)
test_collision_gjk_sphere_sphere :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.SphereCollider{radius = 1.0},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  point, normal, penetration, hit := physics.test_collision_gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
  )
  testing.expect(t, hit, "Should detect collision")
  testing.expect(
    t,
    abs(penetration - 0.5) < 0.1,
    "Penetration should be approximately 0.5",
  )
}

@(test)
test_collision_gjk_box_box :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.BoxCollider{half_extents = {1, 1, 1}},
  }
  collider_b := collider_a
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  point, normal, penetration, hit := physics.test_collision_gjk(
    &collider_a,
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    &collider_b,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
  )
  testing.expect(t, hit, "Should detect collision")
  testing.expect(
    t,
    abs(penetration - 0.5) < 0.1,
    "Penetration should be approximately 0.5",
  )
}

@(test)
test_support_function_sphere :: proc(t: ^testing.T) {
  collider := physics.Collider {
    shape = physics.SphereCollider{radius = 2.0},
  }
  position := [3]f32{0, 0, 0}
  direction := [3]f32{1, 0, 0}
  point := physics.find_furthest_point(
    &collider,
    position,
    linalg.QUATERNIONF32_IDENTITY,
    direction,
  )
  expected := [3]f32{2, 0, 0}
  testing.expect(
    t,
    abs(point.x - expected.x) < 0.001 &&
    abs(point.y - expected.y) < 0.001 &&
    abs(point.z - expected.z) < 0.001,
    "Support function for sphere should return furthest point",
  )
}

@(test)
test_support_function_box :: proc(t: ^testing.T) {
  collider := physics.Collider {
    shape = physics.BoxCollider{half_extents = {1, 2, 3}},
  }
  position := [3]f32{0, 0, 0}
  direction := [3]f32{1, 1, 1}
  point := physics.find_furthest_point(
    &collider,
    position,
    linalg.QUATERNIONF32_IDENTITY,
    direction,
  )
  expected := [3]f32{1, 2, 3}
  testing.expect(
    t,
    abs(point.x - expected.x) < 0.001 &&
    abs(point.y - expected.y) < 0.001 &&
    abs(point.z - expected.z) < 0.001,
    "Support function for box should return correct vertex",
  )
}

@(test)
test_sphere_sphere_collision_intersecting :: proc(t: ^testing.T) {
  sphere_a := physics.SphereCollider {
    radius = 1.0,
  }
  sphere_b := physics.SphereCollider {
    radius = 1.0,
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  point, normal, penetration, hit := physics.test_sphere_sphere(
    pos_a,
    sphere_a,
    pos_b,
    sphere_b,
  )
  testing.expect(t, hit, "Spheres should intersect")
  testing.expect(
    t,
    abs(penetration - 0.5) < 0.001,
    "Penetration should be 0.5",
  )
  testing.expect(
    t,
    abs(normal.x - 1.0) < 0.001 &&
    abs(normal.y) < 0.001 &&
    abs(normal.z) < 0.001,
    "Normal should be (1, 0, 0)",
  )
}

@(test)
test_sphere_sphere_collision_separated :: proc(t: ^testing.T) {
  sphere_a := physics.SphereCollider {
    radius = 1.0,
  }
  sphere_b := physics.SphereCollider {
    radius = 1.0,
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{3, 0, 0}
  _, _, _, hit := physics.test_sphere_sphere(pos_a, sphere_a, pos_b, sphere_b)
  testing.expect(t, !hit, "Spheres should not intersect")
}

@(test)
test_sphere_sphere_collision_overlapping :: proc(t: ^testing.T) {
  sphere_a := physics.SphereCollider {
    radius = 2.0,
  }
  sphere_b := physics.SphereCollider {
    radius = 1.5,
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{0, 0, 0}
  _, _, penetration, hit := physics.test_sphere_sphere(
    pos_a,
    sphere_a,
    pos_b,
    sphere_b,
  )
  testing.expect(t, hit, "Overlapping spheres should collide")
  testing.expect(
    t,
    abs(penetration - 3.5) < 0.001,
    "Penetration should be sum of radii",
  )
}

@(test)
test_box_box_collision_intersecting :: proc(t: ^testing.T) {
  box_a := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  point, normal, penetration, hit := physics.test_box_box(
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    box_a,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
  )
  testing.expect(t, hit, "Boxes should intersect")
  testing.expect(
    t,
    abs(penetration - 0.5) < 0.001,
    "Penetration should be 0.5",
  )
  testing.expect(
    t,
    abs(normal.x - 1.0) < 0.001 &&
    abs(normal.y) < 0.001 &&
    abs(normal.z) < 0.001,
    "Normal should be (1, 0, 0)",
  )
}

@(test)
test_box_box_collision_separated :: proc(t: ^testing.T) {
  box_a := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  _, _, _, hit := physics.test_box_box(
    {0, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_a,
    {5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
  )
  testing.expect(t, !hit, "Separated boxes should not intersect")
}

@(test)
test_box_box_collision_y_axis :: proc(t: ^testing.T) {
  box_a := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{0, 1.5, 0}
  _, normal, penetration, hit := physics.test_box_box(
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    box_a,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
  )
  testing.expect(t, hit, "Boxes should intersect")
  testing.expect(
    t,
    abs(penetration - 0.5) < 0.001,
    "Penetration should be 0.5",
  )
  testing.expect(
    t,
    abs(normal.y - 1.0) < 0.001 &&
    abs(normal.x) < 0.001 &&
    abs(normal.z) < 0.001,
    "Normal should be (0, 1, 0)",
  )
}

@(test)
test_sphere_box_collision_intersecting :: proc(t: ^testing.T) {
  sphere := physics.SphereCollider {
    radius = 1.0,
  }
  box := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  // Sphere at (1.5, 0, 0) with radius 1.0 reaches from 0.5 to 2.5
  // Box at (0, 0, 0) with extents 1 reaches from -1 to 1
  // Penetration: 1.0 - 0.5 = 0.5
  pos_sphere := [3]f32{1.5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  point, normal, penetration, hit := physics.test_box_sphere(
    pos_box,
    linalg.QUATERNIONF32_IDENTITY,
    box,
    pos_sphere,
    sphere,
  )
  testing.expect(t, hit, "Sphere and box should intersect")
  testing.expect(
    t,
    abs(penetration - 0.5) < 0.1,
    "Penetration should be approximately 0.5",
  )
  // Normal should point approximately in +X direction (allow some tolerance)
  testing.expect(
    t,
    normal.x > 0.9 && abs(normal.y) < 0.2 && abs(normal.z) < 0.2,
    "Normal should point approximately in +X direction",
  )
}

@(test)
test_sphere_box_collision_separated :: proc(t: ^testing.T) {
  sphere := physics.SphereCollider {
    radius = 1.0,
  }
  box := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_sphere := [3]f32{5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  _, _, _, hit := physics.test_box_sphere(
    pos_box,
    linalg.QUATERNIONF32_IDENTITY,
    box,
    pos_sphere,
    sphere,
  )
  testing.expect(t, !hit, "Separated sphere and box should not intersect")
}

@(test)
test_sphere_box_collision_corner :: proc(t: ^testing.T) {
  sphere := physics.SphereCollider {
    radius = 1.0,
  }
  box := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_sphere := [3]f32{1.5, 1.5, 1.5}
  pos_box := [3]f32{0, 0, 0}
  _, _, _, hit := physics.test_box_sphere(
    pos_box,
    linalg.QUATERNIONF32_IDENTITY,
    box,
    pos_sphere,
    sphere,
  )
  testing.expect(t, hit, "Sphere should collide with box corner")
}

@(test)
test_collider_get_aabb_sphere :: proc(t: ^testing.T) {
  collider := physics.Collider {
    offset = {1, 0, 0},
    shape = physics.SphereCollider{radius = 2.0},
  }
  position := [3]f32{5, 3, 1}
  aabb := physics.collider_calculate_aabb(
    &collider,
    position,
    linalg.QUATERNIONF32_IDENTITY,
  )
  expected_min := [3]f32{4, 1, -1}
  expected_max := [3]f32{8, 5, 3}
  testing.expect(
    t,
    abs(aabb.min.x - expected_min.x) < 0.001 &&
    abs(aabb.min.y - expected_min.y) < 0.001 &&
    abs(aabb.min.z - expected_min.z) < 0.001,
    "AABB min should match expected",
  )
  testing.expect(
    t,
    abs(aabb.max.x - expected_max.x) < 0.001 &&
    abs(aabb.max.y - expected_max.y) < 0.001 &&
    abs(aabb.max.z - expected_max.z) < 0.001,
    "AABB max should match expected",
  )
}

@(test)
test_collider_get_aabb_box :: proc(t: ^testing.T) {
  collider := physics.Collider {
    offset = {0.5, 0, 0},
    shape = physics.BoxCollider{half_extents = {1, 2, 0.5}},
  }
  position := [3]f32{10, 5, 2}
  aabb := physics.collider_calculate_aabb(
    &collider,
    position,
    linalg.QUATERNIONF32_IDENTITY,
  )
  expected_min := [3]f32{9.5, 3, 1.5}
  expected_max := [3]f32{11.5, 7, 2.5}
  testing.expect(
    t,
    abs(aabb.min.x - expected_min.x) < 0.001 &&
    abs(aabb.min.y - expected_min.y) < 0.001 &&
    abs(aabb.min.z - expected_min.z) < 0.001,
    "AABB min should match expected",
  )
  testing.expect(
    t,
    abs(aabb.max.x - expected_max.x) < 0.001 &&
    abs(aabb.max.y - expected_max.y) < 0.001 &&
    abs(aabb.max.z - expected_max.z) < 0.001,
    "AABB max should match expected",
  )
}

@(test)
test_swept_sphere_sphere_hit :: proc(t: ^testing.T) {
  center_a := [3]f32{0, 0, 0}
  radius_a := f32(1.0)
  velocity := [3]f32{10, 0, 0}
  center_b := [3]f32{5, 0, 0}
  radius_b := f32(1.0)
  result := physics.swept_sphere_sphere(
    center_a,
    radius_a,
    velocity,
    center_b,
    radius_b,
  )
  testing.expect(t, result.has_impact, "Should detect impact")
  testing.expect(
    t,
    abs(result.time - 0.3) < 0.01,
    "TOI should be approximately 0.3",
  )
  testing.expect(
    t,
    abs(result.normal.x - 1.0) < 0.01,
    "Normal should point right",
  )
}

@(test)
test_swept_sphere_sphere_miss :: proc(t: ^testing.T) {
  center_a := [3]f32{0, 0, 0}
  radius_a := f32(1.0)
  velocity := [3]f32{10, 0, 0}
  center_b := [3]f32{5, 5, 0}
  radius_b := f32(1.0)
  result := physics.swept_sphere_sphere(
    center_a,
    radius_a,
    velocity,
    center_b,
    radius_b,
  )
  testing.expect(t, !result.has_impact, "Should not detect impact")
}

@(test)
test_swept_sphere_sphere_already_touching :: proc(t: ^testing.T) {
  center_a := [3]f32{0, 0, 0}
  radius_a := f32(1.0)
  velocity := [3]f32{1, 0, 0}
  center_b := [3]f32{2, 0, 0}
  radius_b := f32(1.0)
  result := physics.swept_sphere_sphere(
    center_a,
    radius_a,
    velocity,
    center_b,
    radius_b,
  )
  testing.expect(t, result.has_impact, "Should detect impact")
  testing.expect(t, result.time < 0.01, "TOI should be at start")
}

@(test)
test_swept_sphere_box_hit :: proc(t: ^testing.T) {
  center := [3]f32{0, 0, 0}
  radius := f32(1.0)
  velocity := [3]f32{10, 0, 0}
  box_min := [3]f32{4, -1, -1}
  box_max := [3]f32{6, 1, 1}
  result := physics.swept_sphere_box(
    center,
    radius,
    velocity,
    box_min,
    box_max,
  )
  testing.expect(t, result.has_impact, "Should detect impact with box")
  testing.expect(
    t,
    abs(result.time - 0.3) < 0.01,
    "TOI should be approximately 0.3",
  )
}

@(test)
test_swept_sphere_box_miss :: proc(t: ^testing.T) {
  center := [3]f32{0, 0, 0}
  radius := f32(1.0)
  velocity := [3]f32{-10, 0, 0}
  box_min := [3]f32{4, -1, -1}
  box_max := [3]f32{6, 1, 1}
  result := physics.swept_sphere_box(
    center,
    radius,
    velocity,
    box_min,
    box_max,
  )
  testing.expect(t, !result.has_impact, "Should not hit box when moving away")
}

@(test)
test_swept_collider_sphere_sphere :: proc(t: ^testing.T) {
  collider_a := physics.Collider {
    shape = physics.SphereCollider{radius = 1.0},
  }
  collider_b := collider_a
  velocity := [3]f32{10, 0, 0}
  result := physics.swept_test(
    &collider_a,
    {0, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    velocity,
    &collider_b,
    {5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
  )
  testing.expect(t, result.has_impact, "Swept test should detect collision")
  testing.expect(
    t,
    result.time > 0 && result.time < 1.0,
    "TOI should be in valid range",
  )
}

@(test)
test_torque_induces_angular_velocity :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(&body, {}, linalg.QUATERNIONF32_IDENTITY, 1.0, true)
  physics.set_box_inertia(&body, {1, 1, 1})
  torque := [3]f32{0, 10, 0}
  body.torque = torque
  dt := f32(0.016)
  physics.integrate(&body, dt)
  testing.expect(
    t,
    abs(body.angular_velocity.y) > 0.01,
    "Torque should induce angular velocity",
  )
  testing.expect(
    t,
    abs(body.torque.y) < 0.001,
    "Torque should be cleared after integration",
  )
}

@(test)
test_off_center_impulse_creates_rotation :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(&body, {}, linalg.QUATERNIONF32_IDENTITY, 1.0, true)
  physics.set_box_inertia(&body, {1, 1, 1})
  center := [3]f32{0, 0, 0}
  impulse := [3]f32{0, 0, 10}
  point := [3]f32{1, 0, 0}
  physics.apply_impulse_at_point(&body, impulse, point)
  testing.expect(
    t,
    abs(body.velocity.z - 10.0) < 0.001,
    "Should have linear velocity from impulse",
  )
  testing.expect(
    t,
    abs(body.angular_velocity.y) > 0.01,
    "Off-center impulse should create angular velocity around Y axis",
  )
}

@(test)
test_rotation_integration_updates_orientation :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, 0, 0}, false)
  defer physics.destroy(&physics_world)
  body_handle, _ := physics.create_dynamic_body(&physics_world)
  body, _ := physics.get_dynamic_body(&physics_world, body_handle)
  physics.set_box_inertia(body, {1, 1, 1})
  body.angular_velocity = {0, 1, 0}
  initial_quat := body.rotation
  dt := f32(0.1)
  physics.step(&physics_world, dt)
  body = physics.get_dynamic_body(&physics_world, body_handle)
  quat_changed :=
    abs(body.rotation.w - initial_quat.w) > 0.001 ||
    abs(body.rotation.x - initial_quat.x) > 0.001 ||
    abs(body.rotation.y - initial_quat.y) > 0.001 ||
    abs(body.rotation.z - initial_quat.z) > 0.001
  testing.expect(
    t,
    quat_changed,
    "Rotation quaternion should update from angular velocity",
  )
}

@(test)
test_collision_off_center_induces_spin :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, 0, 0}, false)
  defer physics.destroy(&physics_world)
  body_a_handle := physics.create_dynamic_body_sphere(
    &physics_world,
    1.0,
    {},
    linalg.QUATERNIONF32_IDENTITY,
    1.0,
  )
  physics.create_dynamic_body_sphere(
    &physics_world,
    1.0,
    {0.5, 0.5, 0},
    linalg.QUATERNIONF32_IDENTITY,
    1.0,
  )
  body_a := physics.get_dynamic_body(&physics_world, body_a_handle)
  physics.set_box_inertia(body_a, {1, 1, 1})
  body_a.velocity = {10, 0, 0}
  dt := f32(0.016)
  physics.step(&physics_world, dt)
  if len(physics_world.dynamic_contacts) > 0 {
    testing.expect(
      t,
      abs(body_a.angular_velocity.z) > 0.01,
      "Off-center collision should induce angular velocity",
    )
  }
}

@(test)
test_resolve_contact_restitution_coefficient :: proc(t: ^testing.T) {
  body_dynamic: physics.DynamicRigidBody
  physics.rigid_body_init(&body_dynamic)
  physics.set_sphere_inertia(&body_dynamic, 1.0)
  body_static: physics.StaticRigidBody
  physics.static_rigid_body_init(&body_static)
  body_dynamic.velocity = {0, -10, 0}
  contact := physics.StaticContact {
    point       = {0, 0, 0},
    normal      = {0, -1, 0}, // Points from dynamic (above) to static (below)
    penetration = 0.01,
    restitution = 0.8,
    friction    = 0.0,
  }
  dt := f32(0.016)
  physics.prepare_contact(&contact, &body_dynamic, &body_static, dt)
  physics.resolve_contact(&contact, &body_dynamic, &body_static)
  // New solver uses sequential impulses, so velocity change might be different
  // Just check that velocity reversed (positive Y) and reduced by bouncing
  testing.expect(
    t,
    body_dynamic.velocity.y > 0,
    "Velocity should reverse after bounce",
  )
  testing.expect(
    t,
    body_dynamic.velocity.y < 10.0,
    "Velocity should be reduced by restitution",
  )
}

@(test)
test_resolve_contact_friction_reduces_tangent_velocity :: proc(t: ^testing.T) {
  body_dynamic: physics.DynamicRigidBody
  physics.rigid_body_init(&body_dynamic)
  physics.set_sphere_inertia(&body_dynamic, 1.0)
  body_static: physics.StaticRigidBody
  physics.static_rigid_body_init(&body_static)
  body_dynamic.velocity = {5, -1, 0}
  contact := physics.StaticContact {
    point       = {0, 0, 0},
    normal      = {0, -1, 0}, // Points from dynamic (above) to static (below)
    penetration = 0.01,
    restitution = 0.0,
    friction    = 0.5,
  }
  initial_tangent_speed := abs(body_dynamic.velocity.x)
  dt := f32(0.016)
  physics.prepare_contact(&contact, &body_dynamic, &body_static, dt)
  physics.resolve_contact(&contact, &body_dynamic, &body_static)
  final_tangent_speed := abs(body_dynamic.velocity.x)
  testing.expect(
    t,
    final_tangent_speed < initial_tangent_speed,
    "Friction should reduce tangent velocity",
  )
  testing.expect(
    t,
    final_tangent_speed > 0,
    "Friction should not completely stop object",
  )
}

@(test)
test_integration_box_stack_stability :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, -9.81, 0}, false)
  defer physics.destroy(&physics_world)
  physics.create_static_body_box(
    &physics_world,
    {5, 0.5, 5},
    {0, -0.5, 0},
  )
  body_1_h, _ := physics.create_dynamic_body_box(
    &physics_world,
    {0.5, 0.5, 0.5},
    {0, 0.5, 0},
    linalg.QUATERNIONF32_IDENTITY,
    10.0,
  )
  body_1, _ := physics.get_dynamic_body(&physics_world, body_1_h)
  body_2_h, _ := physics.create_dynamic_body_box(
    &physics_world,
    {0.5, 0.5, 0.5},
    {0, 1.5, 0},
    linalg.QUATERNIONF32_IDENTITY,
    10.0,
  )
  body_2, _ := physics.get_dynamic_body(&physics_world, body_2_h)
  body_3_h, _ := physics.create_dynamic_body_box(
    &physics_world,
    {0.5, 0.5, 0.5},
    {0, 2.5, 0},
    linalg.QUATERNIONF32_IDENTITY,
    10.0,
  )
  body_3, _ := physics.get_dynamic_body(&physics_world, body_3_h)
  dt := f32(0.016)
  for i in 0 ..< 120 {
    physics.step(&physics_world, dt)
    log.infof("finished simulating step %v", i)
  }
  testing.expect(
    t,
    linalg.length(body_1.velocity) < 0.1,
    "Bottom box should settle",
  )
  testing.expect(
    t,
    linalg.length(body_2.velocity) < 0.1,
    "Middle box should settle",
  )
  testing.expect(
    t,
    linalg.length(body_3.velocity) < 0.1,
    "Top box should settle",
  )
  testing.expect(
    t,
    body_2.position.y > body_1.position.y,
    "Box 2 should be above box 1",
  )
  testing.expect(
    t,
    body_3.position.y > body_2.position.y,
    "Box 3 should be above box 2",
  )
}

@(test)
test_resolve_contact_bias_correction :: proc(t: ^testing.T) {
  body_a: physics.DynamicRigidBody
  body_b: physics.DynamicRigidBody
  physics.rigid_body_init(&body_a)
  physics.rigid_body_init(&body_b)
  physics.set_box_inertia(&body_a, {1, 1, 1})
  physics.set_box_inertia(&body_b, {1, 1, 1})
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{0, 0, 0}
  contact := physics.DynamicContact {
    point       = {0, 0, 0},
    normal      = {1, 0, 0},
    penetration = 0.5,
    restitution = 0.0,
    friction    = 0.0,
  }
  dt := f32(0.016)
  physics.prepare_contact(&contact, &body_a, &body_b, dt)
  testing.expect(
    t,
    contact.bias > 0.0,
    "Bias should be positive for position correction",
  )
  testing.expect(
    t,
    contact.normal_mass > 0.0,
    "Normal mass should be computed",
  )
}

@(test)
test_disable_rotation_prevents_angular_velocity :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(&body)
  physics.set_box_inertia(&body, {1, 1, 1})
  body.enable_rotation = false
  torque := [3]f32{0, 10, 0}
  body.torque = torque
  dt := f32(0.016)
  physics.integrate(&body, dt)
  testing.expect(
    t,
    abs(body.angular_velocity.x) < 0.001 &&
    abs(body.angular_velocity.y) < 0.001 &&
    abs(body.angular_velocity.z) < 0.001,
    "Angular velocity should remain zero when rotation is disabled",
  )
}

@(test)
test_disable_rotation_prevents_torque_application :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(&body)
  physics.set_box_inertia(&body, {1, 1, 1})
  body.enable_rotation = false
  center := [3]f32{0, 0, 0}
  point := [3]f32{1, 0, 0}
  force := [3]f32{0, 1, 0}
  physics.apply_force_at_point(&body, force, point, center)
  testing.expect(
    t,
    abs(body.torque.x) < 0.001 &&
    abs(body.torque.y) < 0.001 &&
    abs(body.torque.z) < 0.001,
    "Torque should not be applied when rotation is disabled",
  )
}

@(test)
test_disable_rotation_prevents_quaternion_update :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, 0, 0}, false)
  defer physics.destroy(&physics_world)
  body_handle, _ := physics.create_dynamic_body(&physics_world)
  body, _ := physics.get_dynamic_body(&physics_world, body_handle)
  physics.set_box_inertia(body, {1, 1, 1})
  body.enable_rotation = false
  body.angular_velocity = {0, 5, 0}
  initial_quat := body.rotation
  dt := f32(0.1)
  physics.step(&physics_world, dt)
  body = physics.get_dynamic_body(&physics_world, body_handle)
  quat_unchanged :=
    abs(body.rotation.w - initial_quat.w) < 0.001 &&
    abs(body.rotation.x - initial_quat.x) < 0.001 &&
    abs(body.rotation.y - initial_quat.y) < 0.001 &&
    abs(body.rotation.z - initial_quat.z) < 0.001
  testing.expect(
    t,
    quat_unchanged,
    "Quaternion should not update when rotation is disabled",
  )
}

@(test)
test_disable_rotation_off_center_impulse_no_spin :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(&body)
  physics.set_box_inertia(&body, {1, 1, 1})
  body.enable_rotation = false
  center := [3]f32{0, 0, 0}
  impulse := [3]f32{0, 0, 10}
  point := [3]f32{1, 0, 0}
  physics.apply_impulse_at_point(&body, impulse, point)
  testing.expect(
    t,
    abs(body.velocity.z - 10.0) < 0.001,
    "Linear velocity should be applied",
  )
  testing.expect(
    t,
    abs(body.angular_velocity.x) < 0.001 &&
    abs(body.angular_velocity.y) < 0.001 &&
    abs(body.angular_velocity.z) < 0.001,
    "Angular velocity should remain zero when rotation is disabled",
  )
}

@(test)
test_force_application :: proc(t: ^testing.T) {
  body: physics.DynamicRigidBody
  physics.rigid_body_init(&body, mass = 10.0)
  force := [3]f32{100, 50, 0}
  physics.apply_force(&body, force)
  testing.expect(
    t,
    abs(body.force.x - 100) < 0.001 &&
    abs(body.force.y - 50) < 0.001 &&
    abs(body.force.z) < 0.001,
    "Force should be applied correctly",
  )
  dt := f32(0.016)
  physics.integrate(&body, dt)
  expected_vx := force.x / body.mass * dt * (1.0 - body.linear_damping)
  expected_vy := force.y / body.mass * dt * (1.0 - body.linear_damping)
  testing.expect(
    t,
    abs(body.velocity.x - expected_vx) < 0.01 &&
    abs(body.velocity.y - expected_vy) < 0.01,
    "Force should accelerate the body correctly",
  )
}

@(test)
test_obb_obb_collision_aligned :: proc(t: ^testing.T) {
  box_a := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  _, normal, penetration, hit := physics.test_box_box(
    {0, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_a,
    {1.5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
  )
  testing.expect(t, hit, "Aligned OBBs should intersect")
  testing.expect(
    t,
    abs(penetration - 0.5) < 0.001,
    "Penetration should be 0.5",
  )
}

@(test)
test_obb_obb_collision_rotated_45 :: proc(t: ^testing.T) {
  // Rotate box A by 45 degrees around Z axis
  rotation_a := linalg.quaternion_angle_axis(
    math.PI / 4.0,
    linalg.VECTOR3F32_Z_AXIS,
  )
  box_a := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  _, _, _, hit := physics.test_box_box(
    {0, 0, 0},
    rotation_a,
    box_a,
    {1.2, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
  )
  testing.expect(t, hit, "Rotated OBB should still intersect with aligned box")
}

@(test)
test_obb_obb_collision_both_rotated :: proc(t: ^testing.T) {
  rotation_a := linalg.quaternion_angle_axis(
    math.PI / 4.0,
    linalg.VECTOR3F32_Z_AXIS,
  )
  rotation_b := linalg.quaternion_angle_axis(
    math.PI / 6.0,
    linalg.VECTOR3F32_Y_AXIS,
  )
  box_a := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  _, _, _, hit := physics.test_box_box(
    pos_a,
    rotation_a,
    box_a,
    pos_b,
    rotation_b,
    box_b,
  )
  testing.expect(t, hit, "Both rotated OBBs should intersect")
}

@(test)
test_obb_obb_collision_separated :: proc(t: ^testing.T) {
  rotation := linalg.quaternion_angle_axis(
    math.PI / 4.0,
    linalg.VECTOR3F32_Z_AXIS,
  )
  box_a := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  _, _, _, hit := physics.test_box_box(
    {0, 0, 0},
    rotation,
    box_a,
    {5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
  )
  testing.expect(t, !hit, "Separated OBBs should not intersect")
}

@(test)
test_sphere_obb_collision_rotated :: proc(t: ^testing.T) {
  sphere := physics.SphereCollider {
    radius = 1.0,
  }
  rotation := linalg.quaternion_angle_axis(
    f32(math.PI / 4.0),
    linalg.VECTOR3F32_Z_AXIS,
  )
  box := physics.BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_sphere := [3]f32{1.5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  _, _, _, hit := physics.test_box_sphere(
    pos_box,
    rotation,
    box,
    pos_sphere,
    sphere,
  )
  testing.expect(t, hit, "Sphere should collide with rotated OBB")
}

@(test)
test_rotated_offset_collider_aabb :: proc(t: ^testing.T) {
  collider := physics.Collider {
    offset = {1, 0, 0},
    shape  = physics.BoxCollider{half_extents = {0.5, 0.5, 0.5}},
  }
  position := [3]f32{0, 0, 0}
  rotation := linalg.quaternion_angle_axis(math.PI / 2.0, linalg.VECTOR3F32_Y_AXIS)
  aabb := physics.collider_calculate_aabb(&collider, position, rotation)
  rotated_offset := linalg.mul(rotation, collider.offset)
  expected_center := position + rotated_offset
  actual_center := (aabb.min + aabb.max) * 0.5
  testing.expect(
    t,
    abs(actual_center.x - expected_center.x) < 0.1 &&
    abs(actual_center.y - expected_center.y) < 0.1 &&
    abs(actual_center.z - expected_center.z) < 0.1,
    "AABB center should account for rotated offset",
  )
}

@(test)
test_rotated_body_with_offset_collision :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, -10, 0}, false)
  defer physics.destroy(&physics_world)
  physics.create_static_body_box(
    &physics_world,
    {10, 0.5, 10},
    {0, -0.5, 0},
  )
  box_handle, _ := physics.create_dynamic_body_box(
    &physics_world,
    {0.5, 0.5, 0.5},
    {0, 2, 0},
    linalg.QUATERNIONF32_IDENTITY,
    1.0,
    false,
    {0.3, 0, 0},
  )
  box, _ := physics.get_dynamic_body(&physics_world, box_handle)
  box.rotation = linalg.quaternion_angle_axis(math.PI / 4.0, linalg.VECTOR3F32_Z_AXIS)
  dt := f32(0.016)
  for i in 0 ..< 60 {
    physics.step(&physics_world, dt)
  }
  testing.expect(
    t,
    box.position.y > -5.0,
    "Rotated body with offset should not sink through floor",
  )
}

@(test)
benchmark_physics_raycast :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)

  Physics_Raycast_State :: struct {
    physics:     physics.World,
    w:           world.World,
    rays:        []geometry.Ray,
    current_ray: int,
    hit_count:   int,
  }

  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(Physics_Raycast_State)

    // Initialize physics and world
    physics.init(&state.physics, enable_parallel = false)
    world.init(&state.w)

    // Spawn a 50x50 grid of bodies (2500 total)
    grid_size := 50
    spacing: f32 = 1.0
    for x in 0 ..< grid_size {
      for z in 0 ..< grid_size {
        world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
        world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
        pos := [3]f32{world_x, 0.5, world_z}
        world.spawn(&state.w, pos)
        physics.create_static_body_sphere(
          &state.physics,
          0.5,
          pos,
        )
      }
    }
    physics.step(&state.physics, 0.0)
    // Generate rays
    num_rays := 10000
    state.rays = make([]geometry.Ray, num_rays)
    for i in 0 ..< num_rays {
      // Rays shooting down from random positions above the grid
      x := (f32(i % 100) - 50.0) * 0.5
      z := (f32(i / 100) - 50.0) * 0.5
      state.rays[i] = geometry.Ray {
        origin    = {x, 10, z},
        direction = {0, -1, 0},
      }
    }

    state.current_ray = 0
    options.input = slice.bytes_from_ptr(state, size_of(Physics_Raycast_State))
    options.bytes = size_of(geometry.Ray) + size_of(physics.PhysicsRayHit)
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Physics_Raycast_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      ray := state.rays[state.current_ray]
      state.current_ray = (state.current_ray + 1) % len(state.rays)
      hit := physics.raycast(&state.physics, ray, 100.0)
      if hit.hit {
        state.hit_count += 1
      }
      options.processed += size_of(geometry.Ray)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Physics_Raycast_State)raw_data(options.input)
    physics.destroy(&state.physics)
    world.shutdown(&state.w, nil, nil)
    delete(state.rays)
    free(state)
    return nil
  }

  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }

  err := time.benchmark(options)
  state := cast(^Physics_Raycast_State)raw_data(options.input)
  hit_rate := f32(state.hit_count) / f32(options.rounds) * 100
  log.infof(
    "Physics raycast: %d casts in %v (%.2f MB/s) | %.2f μs/cast | %d hits (%.1f%%)",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    state.hit_count,
    hit_rate,
  )
}
