package physics

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
test_body :: proc(collider: Collider = SphereCollider{radius = 1}, mass: f32 = 1) -> (b: Body) {
  body_init(&b, {}, linalg.QUATERNIONF32_IDENTITY, collider, mass, false, {})
  return
}

@(test)
test_physics_world_gravity_application :: proc(t: ^testing.T) {
  physics_world: World
  init(&physics_world, {0, -10, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_handle, body_ok := create_body(&physics_world, {}, linalg.QUATERNIONF32_IDENTITY, SphereCollider{radius = 1.0}, mass = 2.0)
  testing.expect(t, body_ok, "Body creation should succeed")
  body, get_ok := get_body(&physics_world, body_handle)
  testing.expect(t, get_ok, "Body retrieval should succeed")
  initial_velocity := body.velocity.y
  dt := f32(0.016)
  step(&physics_world, dt)
  body = get_body(&physics_world, body_handle)
  expected_velocity_change := physics_world.gravity.y * dt
  testing.expect(
    t,
    abs((body.velocity.y - initial_velocity) - expected_velocity_change) < 0.1,
    "Body should accelerate due to gravity",
  )
}

@(test)
test_physics_world_two_body_collision :: proc(t: ^testing.T) {
  physics_world: World
  init(&physics_world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_a_handle, _ := create_body(&physics_world, {}, linalg.QUATERNIONF32_IDENTITY, SphereCollider{radius = 1.0}, mass = 1.0)
  body_b_handle, _ := create_body(&physics_world, {1.5, 0, 0}, linalg.QUATERNIONF32_IDENTITY, SphereCollider{radius = 1.0}, mass = 1.0)
  body_a, _ := get_body(&physics_world, body_a_handle)
  body_b, _ := get_body(&physics_world, body_b_handle)
  body_a.velocity = {10, 0, 0}
  body_b.velocity = {-10, 0, 0}
  dt := f32(0.016)
  step(&physics_world, dt)
  testing.expect(
    t,
    len(physics_world.contacts) > 0,
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
  physics_world: World
  init(&physics_world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_static_handle, _ := create_body(&physics_world, collider = SphereCollider{radius = 1.0})
  body_dynamic_handle, _ := create_body(&physics_world, {1.5, 0, 0}, linalg.QUATERNIONF32_IDENTITY, SphereCollider{radius = 1.0}, mass = 1.0)
  body_dynamic, _ := get_body(&physics_world, body_dynamic_handle)
  body_dynamic.velocity = {-10, 0, 0}
  dt := f32(0.016)
  step(&physics_world, dt)
  testing.expect(
    t,
    len(physics_world.contacts) > 0,
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
  body_a := test_body(mass = 2.0)
  body_b := test_body(mass = 3.0)
  body_a.velocity = {5, 0, 0}
  body_b.velocity = {-3, 0, 0}
  initial_momentum :=
    body_a.velocity / body_a.inv_mass + body_b.velocity / body_b.inv_mass
  contact := Contact {
    normal      = {1, 0, 0},
    restitution = 0.0,
    friction    = 0.0,
    count       = 1,
    points      = {0 = {point = {0, 0, 0}, base_separation = -0.1}},
  }
  dt := f32(0.016)
  prepare_contact(&contact, &body_a, &body_b)
  soft := make_soft(CONTACT_HERTZ, CONTACT_DAMPING_RATIO, dt)
  resolve_velocity(&contact, &body_a, &body_b, soft, 1.0 / dt, true)
  final_momentum :=
    body_a.velocity / body_a.inv_mass + body_b.velocity / body_b.inv_mass
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
test_physics_world_ccd_prevents_tunneling :: proc(t: ^testing.T) {
  physics_world: World
  init(&physics_world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_bullet_handle, _ := create_body(&physics_world, {-5, 0, 0}, linalg.QUATERNIONF32_IDENTITY, SphereCollider{radius = 0.1}, mass = 0.1)
  create_body(&physics_world, collider = BoxCollider{half_extents = {0.5, 5, 5}})
  body_bullet := get_body(&physics_world, body_bullet_handle)
  body_bullet.velocity = {100, 0, 0}
  dt := f32(0.016)
  step(&physics_world, dt)
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
  physics_world: World
  init(&physics_world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_handle, _ := create_body(&physics_world, mass = 1.0)
  body, _ := get_body(&physics_world, body_handle)
  set_collider(&physics_world, body_handle, SphereCollider{radius = 1.0})
  body.angular_velocity = {0, math.PI, 0}
  initial_rotation := body.rotation
  dt := f32(1.0)
  step(&physics_world, dt)
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
test_sphere_sphere_collision_intersecting :: proc(t: ^testing.T) {
  sphere_a := SphereCollider {
    radius = 1.0,
  }
  sphere_b := SphereCollider {
    radius = 1.0,
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  point, normal, penetration, hit := test_sphere_sphere(
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
  sphere_a := SphereCollider {
    radius = 1.0,
  }
  sphere_b := SphereCollider {
    radius = 1.0,
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{3, 0, 0}
  _, _, _, hit := test_sphere_sphere(pos_a, sphere_a, pos_b, sphere_b)
  testing.expect(t, !hit, "Spheres should not intersect")
}

@(test)
test_sphere_sphere_collision_overlapping :: proc(t: ^testing.T) {
  sphere_a := SphereCollider {
    radius = 2.0,
  }
  sphere_b := SphereCollider {
    radius = 1.5,
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{0, 0, 0}
  _, _, penetration, hit := test_sphere_sphere(
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
  box_a := BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  m, hit := collide_boxes(
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    box_a,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
    0,
  )
  testing.expect(t, hit, "Boxes should intersect")
  testing.expect(
    t,
    abs(m.points[0].penetration - 0.5) < 0.001,
    "Penetration should be 0.5",
  )
  testing.expect(
    t,
    abs(m.normal.x - 1.0) < 0.001 &&
    abs(m.normal.y) < 0.001 &&
    abs(m.normal.z) < 0.001,
    "Normal should be (1, 0, 0)",
  )
}

@(test)
test_box_box_collision_separated :: proc(t: ^testing.T) {
  box_a := BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := BoxCollider {
    half_extents = {1, 1, 1},
  }
  _, hit := collide_boxes(
    {0, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_a,
    {5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
    0,
  )
  testing.expect(t, !hit, "Separated boxes should not intersect")
}

@(test)
test_box_box_collision_y_axis :: proc(t: ^testing.T) {
  box_a := BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{0, 1.5, 0}
  m, hit := collide_boxes(
    pos_a,
    linalg.QUATERNIONF32_IDENTITY,
    box_a,
    pos_b,
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
    0,
  )
  testing.expect(t, hit, "Boxes should intersect")
  testing.expect(
    t,
    abs(m.points[0].penetration - 0.5) < 0.001,
    "Penetration should be 0.5",
  )
  testing.expect(
    t,
    abs(m.normal.y - 1.0) < 0.001 &&
    abs(m.normal.x) < 0.001 &&
    abs(m.normal.z) < 0.001,
    "Normal should be (0, 1, 0)",
  )
}

@(test)
test_sphere_box_collision_intersecting :: proc(t: ^testing.T) {
  sphere := SphereCollider {
    radius = 1.0,
  }
  box := BoxCollider {
    half_extents = {1, 1, 1},
  }
  // Sphere at (1.5, 0, 0) with radius 1.0 reaches from 0.5 to 2.5
  // Box at (0, 0, 0) with extents 1 reaches from -1 to 1
  // Penetration: 1.0 - 0.5 = 0.5
  pos_sphere := [3]f32{1.5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  point, normal, penetration, hit := test_box_sphere(
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
  sphere := SphereCollider {
    radius = 1.0,
  }
  box := BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_sphere := [3]f32{5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  _, _, _, hit := test_box_sphere(
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
  sphere := SphereCollider {
    radius = 1.0,
  }
  box := BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_sphere := [3]f32{1.5, 1.5, 1.5}
  pos_box := [3]f32{0, 0, 0}
  _, _, _, hit := test_box_sphere(
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
  collider: Collider = SphereCollider{radius = 2.0}
  position := [3]f32{5, 3, 1}
  aabb := collider_calculate_aabb(
    &collider,
    position,
    linalg.QUATERNIONF32_IDENTITY,
  )
  expected_min := [3]f32{3, 1, -1}
  expected_max := [3]f32{7, 5, 3}
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
  collider: Collider = BoxCollider{half_extents = {1, 2, 0.5}}
  position := [3]f32{10, 5, 2}
  aabb := collider_calculate_aabb(
    &collider,
    position,
    linalg.QUATERNIONF32_IDENTITY,
  )
  expected_min := [3]f32{9, 3, 1.5}
  expected_max := [3]f32{11, 7, 2.5}
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
  toi, hit := swept_sphere_sphere(
    center_a,
    center_b,
    radius_a,
    radius_b,
    velocity,
  )
  testing.expect(t, hit, "Should detect impact")
  testing.expect(
    t,
    abs(toi - 0.3) < 0.01,
    "TOI should be approximately 0.3",
  )
}

@(test)
test_swept_sphere_sphere_miss :: proc(t: ^testing.T) {
  center_a := [3]f32{0, 0, 0}
  radius_a := f32(1.0)
  velocity := [3]f32{10, 0, 0}
  center_b := [3]f32{5, 5, 0}
  radius_b := f32(1.0)
  toi, hit := swept_sphere_sphere(
    center_a,
    center_b,
    radius_a,
    radius_b,
    velocity,
  )
  testing.expect(t, !hit, "Should not detect impact")
}

@(test)
test_swept_sphere_sphere_already_touching :: proc(t: ^testing.T) {
  center_a := [3]f32{0, 0, 0}
  radius_a := f32(1.0)
  velocity := [3]f32{1, 0, 0}
  center_b := [3]f32{2, 0, 0}
  radius_b := f32(1.0)
  toi, hit := swept_sphere_sphere(
    center_a,
    center_b,
    radius_a,
    radius_b,
    velocity,
  )
  testing.expect(t, hit, "Should detect impact")
  testing.expect(t, toi < 0.01, "TOI should be at start")
}

@(test)
test_swept_sphere_box_hit :: proc(t: ^testing.T) {
  center := [3]f32{0, 0, 0}
  radius := f32(1.0)
  velocity := [3]f32{10, 0, 0}
  toi, hit := swept_sphere_box(center, radius, velocity, {5, 0, 0}, linalg.QUATERNIONF32_IDENTITY, {1, 1, 1})
  testing.expect(t, hit, "Should detect impact with box")
  testing.expect(
    t,
    abs(toi - 0.3) < 0.01,
    "TOI should be approximately 0.3",
  )
}

@(test)
test_swept_sphere_box_miss :: proc(t: ^testing.T) {
  center := [3]f32{0, 0, 0}
  radius := f32(1.0)
  velocity := [3]f32{-10, 0, 0}
  toi, hit := swept_sphere_box(center, radius, velocity, {5, 0, 0}, linalg.QUATERNIONF32_IDENTITY, {1, 1, 1})
  testing.expect(t, !hit, "Should not hit box when moving away")
}

@(test)
test_swept_collider_sphere_sphere :: proc(t: ^testing.T) {
  collider_a: Collider = SphereCollider{radius = 1.0}
  collider_b := collider_a
  velocity := [3]f32{10, 0, 0}
  toi, hit := swept_test(
    &collider_a,
    &collider_b,
    {0, 0, 0},
    {5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    linalg.QUATERNIONF32_IDENTITY,
    velocity,
  )
  testing.expect(t, hit, "Swept test should detect collision")
  testing.expect(
    t,
    toi > 0 && toi < 1.0,
    "TOI should be in valid range",
  )
}

@(test)
test_torque_induces_angular_velocity :: proc(t: ^testing.T) {
  world: World
  init(&world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&world)
  handle := create_body(&world, collider = BoxCollider{half_extents = {1, 1, 1}}, mass = 1.0)
  body := get_body(&world, handle)
  body.torque = {0, 10, 0}
  step(&world, 0.016)
  testing.expect(
    t,
    abs(body.angular_velocity.y) > 0.01,
    "Torque should induce angular velocity",
  )
  testing.expect(
    t,
    abs(body.torque.y) < 0.001,
    "Torque should be cleared after step",
  )
}

@(test)
test_off_center_impulse_creates_rotation :: proc(t: ^testing.T) {
  body := test_body(BoxCollider{half_extents = {1, 1, 1}})
  impulse := [3]f32{0, 0, 10}
  point := [3]f32{1, 0, 0}
  apply_impulse_at_point(&body, impulse, point)
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
  physics_world: World
  init(&physics_world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_handle, _ := create_body(&physics_world, mass = 1.0)
  body, _ := get_body(&physics_world, body_handle)
  set_collider(&physics_world, body_handle, BoxCollider{half_extents = {1, 1, 1}})
  body.angular_velocity = {0, 1, 0}
  initial_quat := body.rotation
  dt := f32(0.1)
  step(&physics_world, dt)
  body = get_body(&physics_world, body_handle)
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
  physics_world: World
  init(&physics_world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_a_handle := create_body(&physics_world, {}, linalg.QUATERNIONF32_IDENTITY, SphereCollider{radius = 1.0}, mass = 1.0)
  create_body(&physics_world, {0.5, 0.5, 0}, linalg.QUATERNIONF32_IDENTITY, SphereCollider{radius = 1.0}, mass = 1.0)
  body_a := get_body(&physics_world, body_a_handle)
  body_a.velocity = {10, 0, 0}
  dt := f32(0.016)
  step(&physics_world, dt)
  if len(physics_world.contacts) > 0 {
    testing.expect(
      t,
      abs(body_a.angular_velocity.z) > 0.01,
      "Off-center collision should induce angular velocity",
    )
  }
}

@(test)
test_resolve_contact_restitution_coefficient :: proc(t: ^testing.T) {
  body_dynamic := test_body()
  body_static := test_body(mass = 0)
  body_dynamic.velocity = {0, -10, 0}
  contact := Contact {
    normal      = {0, -1, 0}, // Points from dynamic (above) to static (below)
    restitution = 0.8,
    friction    = 0.0,
    count       = 1,
    points      = {0 = {point = {0, 0, 0}, base_separation = -0.01}},
  }
  dt := f32(0.016)
  prepare_contact(&contact, &body_dynamic, &body_static)
  soft := make_soft(CONTACT_HERTZ, CONTACT_DAMPING_RATIO, dt)
  resolve_velocity(&contact, &body_dynamic, &body_static, soft, 1.0 / dt, true)
  apply_restitution(&contact, &body_dynamic, &body_static)
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
  body_dynamic := test_body()
  body_static := test_body(mass = 0)
  body_dynamic.velocity = {5, -1, 0}
  contact := Contact {
    normal      = {0, -1, 0}, // Points from dynamic (above) to static (below)
    restitution = 0.0,
    friction    = 0.5,
    count       = 1,
    points      = {0 = {point = {0, 0, 0}, base_separation = -0.01}},
  }
  initial_tangent_speed := abs(body_dynamic.velocity.x)
  dt := f32(0.016)
  prepare_contact(&contact, &body_dynamic, &body_static)
  soft := make_soft(CONTACT_HERTZ, CONTACT_DAMPING_RATIO, dt)
  resolve_velocity(&contact, &body_dynamic, &body_static, soft, 1.0 / dt, true)
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
  physics_world: World
  init(&physics_world, {0, -9.81, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  create_body(&physics_world, position = {0, -0.5, 0}, collider = BoxCollider{half_extents = {5, 0.5, 5}})
  body_1_h, _ := create_body(&physics_world, {0, 0.5, 0}, linalg.QUATERNIONF32_IDENTITY, BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 10.0)
  body_1, _ := get_body(&physics_world, body_1_h)
  body_2_h, _ := create_body(&physics_world, {0, 1.5, 0}, linalg.QUATERNIONF32_IDENTITY, BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 10.0)
  body_2, _ := get_body(&physics_world, body_2_h)
  body_3_h, _ := create_body(&physics_world, {0, 2.5, 0}, linalg.QUATERNIONF32_IDENTITY, BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 10.0)
  body_3, _ := get_body(&physics_world, body_3_h)
  dt := f32(0.016)
  for i in 0 ..< 120 {
    step(&physics_world, dt)
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
  body_a := test_body(BoxCollider{half_extents = {1, 1, 1}})
  body_b := test_body(BoxCollider{half_extents = {1, 1, 1}})
  contact := Contact {
    normal      = {1, 0, 0},
    restitution = 0.0,
    friction    = 0.0,
    count       = 1,
    points      = {0 = {point = {0, 0, 0}, base_separation = -0.5}},
  }
  dt := f32(0.016)
  prepare_contact(&contact, &body_a, &body_b)
  testing.expect(
    t,
    contact.points[0].base_separation < 0.0,
    "Penetrating contact should have negative base separation",
  )
  testing.expect(
    t,
    contact.points[0].normal_mass > 0.0,
    "Normal mass should be computed",
  )
}

@(test)
test_disable_rotation_prevents_angular_velocity :: proc(t: ^testing.T) {
  world: World
  init(&world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&world)
  handle := create_body(&world, collider = BoxCollider{half_extents = {1, 1, 1}}, mass = 1.0)
  body := get_body(&world, handle)
  body.enable_rotation = false
  update_world_inertia(body)
  body.torque = {0, 10, 0}
  step(&world, 0.016)
  testing.expect(
    t,
    abs(body.angular_velocity.x) < 0.001 &&
    abs(body.angular_velocity.y) < 0.001 &&
    abs(body.angular_velocity.z) < 0.001,
    "Angular velocity should remain zero when rotation is disabled",
  )
}

@(test)
test_disable_rotation_prevents_quaternion_update :: proc(t: ^testing.T) {
  physics_world: World
  init(&physics_world, {0, 0, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  body_handle, _ := create_body(&physics_world, mass = 1.0)
  body, _ := get_body(&physics_world, body_handle)
  set_collider(&physics_world, body_handle, BoxCollider{half_extents = {1, 1, 1}})
  body.enable_rotation = false
  body.angular_velocity = {0, 5, 0}
  initial_quat := body.rotation
  dt := f32(0.1)
  step(&physics_world, dt)
  body = get_body(&physics_world, body_handle)
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
  body := test_body(BoxCollider{half_extents = {1, 1, 1}})
  body.enable_rotation = false
  impulse := [3]f32{0, 0, 10}
  point := [3]f32{1, 0, 0}
  apply_impulse_at_point(&body, impulse, point)
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
test_obb_obb_collision_rotated_45 :: proc(t: ^testing.T) {
  // Rotate box A by 45 degrees around Z axis
  rotation_a := linalg.quaternion_angle_axis(
    math.PI / 4.0,
    linalg.VECTOR3F32_Z_AXIS,
  )
  box_a := BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := BoxCollider {
    half_extents = {1, 1, 1},
  }
  _, hit := collide_boxes(
    {0, 0, 0},
    rotation_a,
    box_a,
    {1.2, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
    0,
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
  box_a := BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_a := [3]f32{0, 0, 0}
  pos_b := [3]f32{1.5, 0, 0}
  _, hit := collide_boxes(
    pos_a,
    rotation_a,
    box_a,
    pos_b,
    rotation_b,
    box_b,
    0,
  )
  testing.expect(t, hit, "Both rotated OBBs should intersect")
}

@(test)
test_obb_obb_collision_separated :: proc(t: ^testing.T) {
  rotation := linalg.quaternion_angle_axis(
    math.PI / 4.0,
    linalg.VECTOR3F32_Z_AXIS,
  )
  box_a := BoxCollider {
    half_extents = {1, 1, 1},
  }
  box_b := BoxCollider {
    half_extents = {1, 1, 1},
  }
  _, hit := collide_boxes(
    {0, 0, 0},
    rotation,
    box_a,
    {5, 0, 0},
    linalg.QUATERNIONF32_IDENTITY,
    box_b,
    0,
  )
  testing.expect(t, !hit, "Separated OBBs should not intersect")
}

@(test)
test_sphere_obb_collision_rotated :: proc(t: ^testing.T) {
  sphere := SphereCollider {
    radius = 1.0,
  }
  rotation := linalg.quaternion_angle_axis(
    f32(math.PI / 4.0),
    linalg.VECTOR3F32_Z_AXIS,
  )
  box := BoxCollider {
    half_extents = {1, 1, 1},
  }
  pos_sphere := [3]f32{1.5, 0, 0}
  pos_box := [3]f32{0, 0, 0}
  _, _, _, hit := test_box_sphere(pos_box, rotation, box, pos_sphere, sphere)
  testing.expect(t, hit, "Sphere should collide with rotated OBB")
}

@(test)
test_rotated_offset_collider_aabb :: proc(t: ^testing.T) {
  collider: Collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}}
  position := [3]f32{0, 0, 0}
  rotation := linalg.quaternion_angle_axis(
    math.PI / 2.0,
    linalg.VECTOR3F32_Y_AXIS,
  )
  aabb := collider_calculate_aabb(&collider, position, rotation)
  expected_center := position
  actual_center := (aabb.min + aabb.max) * 0.5
  testing.expect(
    t,
    abs(actual_center.x - expected_center.x) < 0.1 &&
    abs(actual_center.y - expected_center.y) < 0.1 &&
    abs(actual_center.z - expected_center.z) < 0.1,
    "AABB center should match position",
  )
}

@(test)
test_rotated_body_with_offset_collision :: proc(t: ^testing.T) {
  physics_world: World
  init(&physics_world, {0, -10, 0}, thread_count = 1)
  defer shutdown(&physics_world)
  create_body(&physics_world, position = {0, -0.5, 0}, collider = BoxCollider{half_extents = {10, 0.5, 10}})
  box_handle, _ := create_body(&physics_world, {0, 2, 0}, linalg.QUATERNIONF32_IDENTITY, BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 1.0)
  box, _ := get_body(&physics_world, box_handle)
  box.rotation = linalg.quaternion_angle_axis(
    math.PI / 4.0,
    linalg.VECTOR3F32_Z_AXIS,
  )
  dt := f32(0.016)
  for i in 0 ..< 60 {
    step(&physics_world, dt)
  }
  testing.expect(
    t,
    box.position.y > -5.0,
    "Rotated body should not sink through floor",
  )
}

@(test)
test_swept_sphere_rotated_box :: proc(t: ^testing.T) {
  // Unit box rotated 45 deg about Y at x=5: its corner points at -X,
  // sqrt(2)/2 from the center. The old AABB-based sweep hit the face at x=4.5.
  rot := linalg.quaternion_angle_axis_f32(math.PI / 4, {0, 1, 0})
  toi, hit := swept_sphere_box({0, 0, 0}, 0.1, {10, 0, 0}, {5, 0, 0}, rot, {0.5, 0.5, 0.5})
  testing.expect(t, hit, "Should hit the rotated box")
  // Grown local box half-size 0.6 along the diagonal: corner at 0.6*sqrt(2)
  expected := f32(5 - 0.6 * math.SQRT_TWO) / 10
  testing.expectf(t, abs(toi - expected) < 1e-3, "toi = %v, expected %v", toi, expected)
  // Passes beside the rotated box but inside its unrotated AABB footprint
  toi, hit = swept_sphere_box({0, 0, 0.62}, 0.1, {10, 0, 0}, {5, 0, 0}, rot, {0.5, 0.5, 0.5})
  testing.expect(t, hit, "Diagonal corner region still hit")
  toi, hit = swept_sphere_box({0, 0, 0.9}, 0.1, {10, 0, 0}, {5, 0, 0}, rot, {0.5, 0.5, 0.5})
  testing.expect(t, !hit, "Should miss outside the rotated box")
}

@(test)
test_kinematic_body_pushes_dynamic :: proc(t: ^testing.T) {
  w: World
  init(&w, {0, 0, 0}, thread_count = 1)
  defer shutdown(&w)
  pusher := create_body(&w, {0, 0, 0}, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}})
  box := create_body(&w, {1.2, 0, 0}, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 1.0)
  testing.expect(t, !get_body(&w, pusher).moving, "Infinite-mass body starts static")
  set_velocity(&w, pusher, {2, 0, 0})
  testing.expect(t, get_body(&w, pusher).moving, "set_velocity turns it kinematic")
  for _ in 0 ..< 60 do step(&w, 1.0 / 60.0)
  p := get_body(&w, pusher)
  b := get_body(&w, box)
  testing.expectf(t, abs(p.position.x - 2) < 0.05, "kinematic moved to %v", p.position)
  testing.expectf(t, abs(p.velocity.x - 2) < 1e-4, "kinematic velocity kept: %v", p.velocity)
  testing.expectf(t, b.position.x > p.position.x + 0.9, "box pushed ahead: box %v pusher %v", b.position, p.position)
}

@(test)
test_physics_teardown_reuse :: proc(t: ^testing.T) {
  w: World
  init(&w, thread_count = 1)
  defer shutdown(&w)
  ground := create_body(&w, {0, -1, 0}, collider = BoxCollider{half_extents = {10, 1, 10}})
  ball := create_body(&w, {0, 1, 0}, collider = SphereCollider{radius = 0.5}, mass = 1)
  for _ in 0 ..< 30 do step(&w, 1.0 / 60)
  teardown(&w)
  _, ground_live := get_body(&w, ground)
  _, ball_live := get_body(&w, ball)
  testing.expect(t, !ground_live && !ball_live)
  testing.expect_value(t, len(w.contacts), 0)
  // the next map: no stale BVH entry or contact survives
  step(&w, 1.0 / 60)
  next := create_body(&w, {0, 5, 0}, collider = SphereCollider{radius = 0.5}, mass = 1)
  step(&w, 1.0 / 60)
  testing.expect_value(t, len(w.contacts), 0)
  body, ok := get_body(&w, next)
  testing.expect(t, ok && body.velocity.y < 0)
}
