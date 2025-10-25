package tests

import "core:math"
import "core:testing"
import "core:time"
import "../mjolnir/geometry"
import "../mjolnir/physics"
import "../mjolnir/resources"
import "../mjolnir/world"

@(test)
test_rigid_body_creation :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 10.0, false)
	testing.expect(t, body.node_handle == node_handle, "Node handle should match")
	testing.expect(t, body.mass == 10.0, "Mass should be 10.0")
	testing.expect(t, abs(body.inv_mass - 0.1) < 0.001, "Inverse mass should be 0.1")
	testing.expect(t, !body.is_static, "Body should not be static")
	testing.expect(t, body.restitution == 0.5, "Default restitution should be 0.5")
	testing.expect(t, body.friction == 0.5, "Default friction should be 0.5")
	testing.expect(t, body.gravity_scale == 1.0, "Default gravity scale should be 1.0")
}

@(test)
test_rigid_body_static_creation :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 10.0, true)
	testing.expect(t, body.is_static, "Body should be static")
	testing.expect(t, body.inv_mass == 0.0, "Static body should have zero inverse mass")
}

@(test)
test_rigid_body_box_inertia :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 12.0, false)
	physics.rigid_body_set_box_inertia(&body, {1, 2, 3})
	expected_ixx := (12.0 / 3.0) * (4.0 + 9.0)
	expected_iyy := (12.0 / 3.0) * (1.0 + 9.0)
	expected_izz := (12.0 / 3.0) * (1.0 + 4.0)
	testing.expect(
		t,
		abs(body.inertia[0, 0] - expected_ixx) < 0.001,
		"Ixx should match calculated value",
	)
	testing.expect(
		t,
		abs(body.inertia[1, 1] - expected_iyy) < 0.001,
		"Iyy should match calculated value",
	)
	testing.expect(
		t,
		abs(body.inertia[2, 2] - expected_izz) < 0.001,
		"Izz should match calculated value",
	)
}

@(test)
test_rigid_body_sphere_inertia :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 5.0, false)
	physics.rigid_body_set_sphere_inertia(&body, 2.0)
	expected_i := (2.0 / 5.0) * 5.0 * 4.0
	testing.expect(
		t,
		abs(body.inertia[0, 0] - expected_i) < 0.001,
		"Inertia should match calculated value",
	)
	testing.expect(
		t,
		abs(body.inertia[1, 1] - expected_i) < 0.001,
		"Inertia should match calculated value",
	)
	testing.expect(
		t,
		abs(body.inertia[2, 2] - expected_i) < 0.001,
		"Inertia should match calculated value",
	)
}

@(test)
test_rigid_body_apply_force :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 10.0, false)
	force := [3]f32{100, 0, 0}
	physics.rigid_body_apply_force(&body, force)
	testing.expect(
		t,
		abs(body.force.x - 100) < 0.001 && abs(body.force.y) < 0.001 && abs(body.force.z) < 0.001,
		"Force should be accumulated",
	)
}

@(test)
test_rigid_body_apply_impulse :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 10.0, false)
	impulse := [3]f32{50, 0, 0}
	physics.rigid_body_apply_impulse(&body, impulse)
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
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 10.0, false)
	force := [3]f32{100, 0, 0}
	physics.rigid_body_apply_force(&body, force)
	dt := f32(0.016)
	physics.rigid_body_integrate(&body, dt)
	expected_velocity := force * body.inv_mass * dt
	testing.expect(
		t,
		abs(body.velocity.x - expected_velocity.x) < 0.001 &&
		abs(body.velocity.y - expected_velocity.y) < 0.001 &&
		abs(body.velocity.z - expected_velocity.z) < 0.001,
		"Velocity should integrate force over time",
	)
	testing.expect(
		t,
		abs(body.force.x) < 0.001 && abs(body.force.y) < 0.001 && abs(body.force.z) < 0.001,
		"Force should be cleared after integration",
	)
}

@(test)
test_rigid_body_static_no_force :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	node_handle := resources.Handle{index = 1, generation = 1}
	body := physics.rigid_body_create(node_handle, 10.0, true)
	force := [3]f32{100, 0, 0}
	physics.rigid_body_apply_force(&body, force)
	testing.expect(
		t,
		abs(body.force.x) < 0.001 && abs(body.force.y) < 0.001 && abs(body.force.z) < 0.001,
		"Static body should ignore forces",
	)
}

@(test)
test_physics_world_init_destroy :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	physics_world := physics.PhysicsWorld{}
	physics.physics_world_init(&physics_world, {0, -10, 0})
	testing.expect(
		t,
		abs(physics_world.gravity.y + 10) < 0.001,
		"Gravity should be set correctly",
	)
	testing.expect(t, physics_world.iterations == 4, "Default iterations should be 4")
	physics.physics_world_destroy(&physics_world)
}

@(test)
test_physics_world_create_destroy_body :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	physics_world := physics.PhysicsWorld{}
	physics.physics_world_init(&physics_world)
	defer physics.physics_world_destroy(&physics_world)
	node_handle := resources.Handle{index = 1, generation = 1}
	body_handle, body, ok := physics.physics_world_create_body(
		&physics_world,
		node_handle,
		5.0,
		false,
	)
	testing.expect(t, ok, "Body creation should succeed")
	testing.expect(t, body != nil, "Body pointer should not be nil")
	testing.expect(t, body.mass == 5.0, "Body mass should match")
	retrieved_body := resources.pool_get(&physics_world.bodies, body_handle)
	testing.expect(t, retrieved_body != nil, "Should retrieve body from pool")
	testing.expect(t, retrieved_body.mass == 5.0, "Retrieved body mass should match")
	physics.physics_world_destroy_body(&physics_world, body_handle)
	destroyed_body := resources.pool_get(&physics_world.bodies, body_handle)
	testing.expect(t, destroyed_body == nil, "Destroyed body should not be retrievable")
}

@(test)
test_physics_world_add_collider :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	physics_world := physics.PhysicsWorld{}
	physics.physics_world_init(&physics_world)
	defer physics.physics_world_destroy(&physics_world)
	node_handle := resources.Handle{index = 1, generation = 1}
	body_handle, body, _ := physics.physics_world_create_body(
		&physics_world,
		node_handle,
		5.0,
		false,
	)
	collider := physics.collider_create_sphere(2.0)
	collider_handle, col_ptr, ok := physics.physics_world_add_collider(
		&physics_world,
		body_handle,
		collider,
	)
	testing.expect(t, ok, "Collider addition should succeed")
	testing.expect(t, col_ptr != nil, "Collider pointer should not be nil")
	testing.expect(t, body.collider_handle == collider_handle, "Body should reference collider")
	retrieved_collider := resources.pool_get(&physics_world.colliders, collider_handle)
	testing.expect(t, retrieved_collider != nil, "Should retrieve collider from pool")
}

@(test)
test_physics_world_gravity_application :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	w := world.World{}
	world.init(&w)
	defer world.destroy(&w, nil, nil)
	physics_world := physics.PhysicsWorld{}
	physics.physics_world_init(&physics_world, {0, -10, 0})
	defer physics.physics_world_destroy(&physics_world)
	node_handle, _, _ := world.spawn(&w)
	body_handle, body, _ := physics.physics_world_create_body(
		&physics_world,
		node_handle,
		2.0,
		false,
	)
	initial_velocity := body.velocity.y
	dt := f32(0.016)
	physics.physics_world_step(&physics_world, &w, dt)
	expected_velocity_change := physics_world.gravity.y * dt
	testing.expect(
		t,
		abs((body.velocity.y - initial_velocity) - expected_velocity_change) < 0.1,
		"Body should accelerate due to gravity",
	)
}

@(test)
test_physics_world_two_body_collision :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	w := world.World{}
	world.init(&w)
	defer world.destroy(&w, nil, nil)
	physics_world := physics.PhysicsWorld{}
	physics.physics_world_init(&physics_world, {0, 0, 0})
	defer physics.physics_world_destroy(&physics_world)
	node_a, node_a_ptr, _ := world.spawn_at(&w, {0, 0, 0})
	node_b, node_b_ptr, _ := world.spawn_at(&w, {1.5, 0, 0})
	body_a_handle, body_a, _ := physics.physics_world_create_body(&physics_world, node_a, 1.0)
	body_b_handle, body_b, _ := physics.physics_world_create_body(&physics_world, node_b, 1.0)
	collider_a := physics.collider_create_sphere(1.0)
	collider_b := physics.collider_create_sphere(1.0)
	physics.physics_world_add_collider(&physics_world, body_a_handle, collider_a)
	physics.physics_world_add_collider(&physics_world, body_b_handle, collider_b)
	body_a.velocity = {10, 0, 0}
	body_b.velocity = {-10, 0, 0}
	dt := f32(0.016)
	physics.physics_world_step(&physics_world, &w, dt)
	testing.expect(t, len(physics_world.contacts) > 0, "Collision should be detected")
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
	testing.set_fail_timeout(t, 30 * time.Second)
	w := world.World{}
	world.init(&w)
	defer world.destroy(&w, nil, nil)
	physics_world := physics.PhysicsWorld{}
	physics.physics_world_init(&physics_world, {0, 0, 0})
	defer physics.physics_world_destroy(&physics_world)
	node_static, _, _ := world.spawn_at(&w, {0, 0, 0})
	node_dynamic, _, _ := world.spawn_at(&w, {1.5, 0, 0})
	body_static_handle, body_static, _ := physics.physics_world_create_body(
		&physics_world,
		node_static,
		1.0,
		true,
	)
	body_dynamic_handle, body_dynamic, _ := physics.physics_world_create_body(
		&physics_world,
		node_dynamic,
		1.0,
		false,
	)
	collider := physics.collider_create_sphere(1.0)
	physics.physics_world_add_collider(&physics_world, body_static_handle, collider)
	physics.physics_world_add_collider(&physics_world, body_dynamic_handle, collider)
	body_dynamic.velocity = {-10, 0, 0}
	initial_static_velocity := body_static.velocity
	dt := f32(0.016)
	physics.physics_world_step(&physics_world, &w, dt)
	testing.expect(t, len(physics_world.contacts) > 0, "Collision should be detected")
	testing.expect(
		t,
		body_static.velocity == initial_static_velocity,
		"Static body velocity should not change",
	)
	testing.expect(
		t,
		body_dynamic.velocity.x > -10.0,
		"Dynamic body should bounce off static body",
	)
}
