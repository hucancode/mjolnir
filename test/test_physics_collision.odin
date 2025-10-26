package tests

import "core:math"
import "core:testing"
import "core:time"
import "../mjolnir/physics"

@(test)
test_sphere_sphere_collision_intersecting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere_a := physics.SphereCollider{radius = 1.0}
	sphere_b := physics.SphereCollider{radius = 1.0}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	hit, point, normal, penetration := physics.test_sphere_sphere(
		pos_a,
		&sphere_a,
		pos_b,
		&sphere_b,
	)
	testing.expect(t, hit, "Spheres should intersect")
	testing.expect(
		t,
		abs(penetration - 0.5) < 0.001,
		"Penetration should be 0.5",
	)
	testing.expect(
		t,
		abs(normal.x - 1.0) < 0.001 && abs(normal.y) < 0.001 && abs(normal.z) < 0.001,
		"Normal should be (1, 0, 0)",
	)
}

@(test)
test_sphere_sphere_collision_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere_a := physics.SphereCollider{radius = 1.0}
	sphere_b := physics.SphereCollider{radius = 1.0}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{3, 0, 0}
	hit, _, _, _ := physics.test_sphere_sphere(pos_a, &sphere_a, pos_b, &sphere_b)
	testing.expect(t, !hit, "Spheres should not intersect")
}

@(test)
test_sphere_sphere_collision_touching :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere_a := physics.SphereCollider{radius = 1.0}
	sphere_b := physics.SphereCollider{radius = 1.0}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{2.0, 0, 0}
	hit, _, _, penetration := physics.test_sphere_sphere(pos_a, &sphere_a, pos_b, &sphere_b)
	testing.expect(t, !hit, "Spheres exactly touching should not register as collision")
}

@(test)
test_sphere_sphere_collision_overlapping :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere_a := physics.SphereCollider{radius = 2.0}
	sphere_b := physics.SphereCollider{radius = 1.5}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{0, 0, 0}
	hit, _, _, penetration := physics.test_sphere_sphere(pos_a, &sphere_a, pos_b, &sphere_b)
	testing.expect(t, hit, "Overlapping spheres should collide")
	testing.expect(t, abs(penetration - 3.5) < 0.001, "Penetration should be sum of radii")
}

@(test)
test_box_box_collision_intersecting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	box_a := physics.BoxCollider{half_extents = {1, 1, 1}}
	box_b := physics.BoxCollider{half_extents = {1, 1, 1}}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	hit, point, normal, penetration := physics.test_box_box(pos_a, &box_a, pos_b, &box_b)
	testing.expect(t, hit, "Boxes should intersect")
	testing.expect(t, abs(penetration - 0.5) < 0.001, "Penetration should be 0.5")
	testing.expect(
		t,
		abs(normal.x - 1.0) < 0.001 && abs(normal.y) < 0.001 && abs(normal.z) < 0.001,
		"Normal should be (1, 0, 0)",
	)
}

@(test)
test_box_box_collision_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	box_a := physics.BoxCollider{half_extents = {1, 1, 1}}
	box_b := physics.BoxCollider{half_extents = {1, 1, 1}}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{5, 0, 0}
	hit, _, _, _ := physics.test_box_box(pos_a, &box_a, pos_b, &box_b)
	testing.expect(t, !hit, "Separated boxes should not intersect")
}

@(test)
test_box_box_collision_y_axis :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	box_a := physics.BoxCollider{half_extents = {1, 1, 1}}
	box_b := physics.BoxCollider{half_extents = {1, 1, 1}}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{0, 1.5, 0}
	hit, _, normal, penetration := physics.test_box_box(pos_a, &box_a, pos_b, &box_b)
	testing.expect(t, hit, "Boxes should intersect")
	testing.expect(t, abs(penetration - 0.5) < 0.001, "Penetration should be 0.5")
	testing.expect(
		t,
		abs(normal.y - 1.0) < 0.001 && abs(normal.x) < 0.001 && abs(normal.z) < 0.001,
		"Normal should be (0, 1, 0)",
	)
}

@(test)
test_sphere_box_collision_intersecting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere := physics.SphereCollider{radius = 1.0}
	box := physics.BoxCollider{half_extents = {1, 1, 1}}
	pos_sphere := [3]f32{2.5, 0, 0}
	pos_box := [3]f32{0, 0, 0}
	hit, point, normal, penetration := physics.test_sphere_box(
		pos_sphere,
		&sphere,
		pos_box,
		&box,
	)
	testing.expect(t, hit, "Sphere and box should intersect")
	testing.expect(t, abs(penetration - 0.5) < 0.001, "Penetration should be 0.5")
	testing.expect(
		t,
		abs(normal.x - 1.0) < 0.001 && abs(normal.y) < 0.001 && abs(normal.z) < 0.001,
		"Normal should be (1, 0, 0)",
	)
}

@(test)
test_sphere_box_collision_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere := physics.SphereCollider{radius = 1.0}
	box := physics.BoxCollider{half_extents = {1, 1, 1}}
	pos_sphere := [3]f32{5, 0, 0}
	pos_box := [3]f32{0, 0, 0}
	hit, _, _, _ := physics.test_sphere_box(pos_sphere, &sphere, pos_box, &box)
	testing.expect(t, !hit, "Separated sphere and box should not intersect")
}

@(test)
test_sphere_box_collision_corner :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere := physics.SphereCollider{radius = 1.0}
	box := physics.BoxCollider{half_extents = {1, 1, 1}}
	pos_sphere := [3]f32{1.5, 1.5, 1.5}
	pos_box := [3]f32{0, 0, 0}
	hit, _, _, _ := physics.test_sphere_box(pos_sphere, &sphere, pos_box, &box)
	testing.expect(t, hit, "Sphere should collide with box corner")
}

@(test)
test_capsule_capsule_collision_parallel :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	capsule_a := physics.CapsuleCollider{radius = 0.5, height = 2.0}
	capsule_b := physics.CapsuleCollider{radius = 0.5, height = 2.0}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{0.8, 0, 0}
	hit, _, _, penetration := physics.test_capsule_capsule(
		pos_a,
		&capsule_a,
		pos_b,
		&capsule_b,
	)
	testing.expect(t, hit, "Parallel capsules should intersect")
	testing.expect(t, abs(penetration - 0.2) < 0.001, "Penetration should be 0.2")
}

@(test)
test_capsule_capsule_collision_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	capsule_a := physics.CapsuleCollider{radius = 0.5, height = 2.0}
	capsule_b := physics.CapsuleCollider{radius = 0.5, height = 2.0}
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{5, 0, 0}
	hit, _, _, _ := physics.test_capsule_capsule(pos_a, &capsule_a, pos_b, &capsule_b)
	testing.expect(t, !hit, "Separated capsules should not intersect")
}

@(test)
test_sphere_capsule_collision :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	sphere := physics.SphereCollider{radius = 1.0}
	capsule := physics.CapsuleCollider{radius = 0.5, height = 2.0}
	pos_sphere := [3]f32{1.2, 0, 0}
	pos_capsule := [3]f32{0, 0, 0}
	hit, _, _, penetration := physics.test_sphere_capsule(
		pos_sphere,
		&sphere,
		pos_capsule,
		&capsule,
	)
	testing.expect(t, hit, "Sphere and capsule should intersect")
	testing.expect(t, abs(penetration - 0.3) < 0.001, "Penetration should be 0.3")
}

@(test)
test_box_capsule_collision :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	box := physics.BoxCollider{half_extents = {1, 1, 1}}
	capsule := physics.CapsuleCollider{radius = 0.5, height = 2.0}
	pos_box := [3]f32{0, 0, 0}
	pos_capsule := [3]f32{1.3, 0, 0}
	hit, _, _, _ := physics.test_box_capsule(pos_box, &box, pos_capsule, &capsule)
	testing.expect(t, hit, "Box and capsule should intersect")
}

@(test)
test_collider_get_aabb_sphere :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider := physics.collider_create_sphere(2.0, {1, 0, 0})
	position := [3]f32{5, 3, 1}
	aabb := physics.collider_get_aabb(&collider, position)
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
	testing.set_fail_timeout(t, 30 * time.Second)
	collider := physics.collider_create_box({1, 2, 0.5}, {0.5, 0, 0})
	position := [3]f32{10, 5, 2}
	aabb := physics.collider_get_aabb(&collider, position)
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
test_collider_get_aabb_capsule :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider := physics.collider_create_capsule(1.0, 4.0)
	position := [3]f32{0, 0, 0}
	aabb := physics.collider_get_aabb(&collider, position)
	expected_min := [3]f32{-1, -3, -1}
	expected_max := [3]f32{1, 3, 1}
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
