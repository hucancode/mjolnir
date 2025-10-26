package tests

import "core:math"
import "core:testing"
import "core:time"
import "../mjolnir/physics"

@(test)
test_gjk_sphere_sphere_intersecting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_sphere(1.0)
	collider_b := physics.collider_create_sphere(1.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex)
	testing.expect(t, result, "GJK should detect collision between intersecting spheres")
}

@(test)
test_gjk_sphere_sphere_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_sphere(1.0)
	collider_b := physics.collider_create_sphere(1.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{3, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex)
	testing.expect(t, !result, "GJK should not detect collision between separated spheres")
}

@(test)
test_gjk_sphere_sphere_touching :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_sphere(1.0)
	collider_b := physics.collider_create_sphere(1.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{2.0, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex)
	testing.expect(t, !result, "GJK should not detect collision for exactly touching spheres")
}

@(test)
test_gjk_box_box_intersecting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_box({1, 1, 1})
	collider_b := physics.collider_create_box({1, 1, 1})
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex)
	testing.expect(t, result, "GJK should detect collision between intersecting boxes")
}

@(test)
test_gjk_box_box_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_box({1, 1, 1})
	collider_b := physics.collider_create_box({1, 1, 1})
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{5, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex)
	testing.expect(t, !result, "GJK should not detect collision between separated boxes")
}

@(test)
test_gjk_sphere_box_intersecting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_sphere := physics.collider_create_sphere(1.0)
	collider_box := physics.collider_create_box({1, 1, 1})
	pos_sphere := [3]f32{2.5, 0, 0}
	pos_box := [3]f32{0, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_sphere, pos_sphere, &collider_box, pos_box, &simplex)
	testing.expect(t, result, "GJK should detect collision between sphere and box")
}

@(test)
test_gjk_sphere_box_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_sphere := physics.collider_create_sphere(1.0)
	collider_box := physics.collider_create_box({1, 1, 1})
	pos_sphere := [3]f32{5, 0, 0}
	pos_box := [3]f32{0, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_sphere, pos_sphere, &collider_box, pos_box, &simplex)
	testing.expect(t, !result, "GJK should not detect collision when sphere and box are separated")
}

@(test)
test_gjk_capsule_capsule_intersecting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_capsule(0.5, 2.0)
	collider_b := physics.collider_create_capsule(0.5, 2.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{0.8, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex)
	testing.expect(t, result, "GJK should detect collision between intersecting capsules")
}

@(test)
test_gjk_capsule_capsule_separated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_capsule(0.5, 2.0)
	collider_b := physics.collider_create_capsule(0.5, 2.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{5, 0, 0}
	simplex := physics.Simplex{}
	result := physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex)
	testing.expect(t, !result, "GJK should not detect collision between separated capsules")
}

@(test)
test_epa_sphere_sphere_penetration :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_sphere(1.0)
	collider_b := physics.collider_create_sphere(1.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	simplex := physics.Simplex{}
	if !physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex) {
		testing.fail_now(t, "GJK should detect collision")
	}
	normal, depth, ok := physics.epa(simplex, &collider_a, pos_a, &collider_b, pos_b)
	testing.expect(t, ok, "EPA should succeed")
	testing.expect(t, abs(depth - 0.5) < 0.1, "EPA depth should be approximately 0.5")
	normal_length := abs(normal.x) + abs(normal.y) + abs(normal.z)
	testing.expect(t, abs(normal_length - 1.0) < 0.1, "Normal should be normalized")
}

@(test)
test_epa_box_box_penetration :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_box({1, 1, 1})
	collider_b := physics.collider_create_box({1, 1, 1})
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	simplex := physics.Simplex{}
	if !physics.gjk(&collider_a, pos_a, &collider_b, pos_b, &simplex) {
		testing.fail_now(t, "GJK should detect collision")
	}
	normal, depth, ok := physics.epa(simplex, &collider_a, pos_a, &collider_b, pos_b)
	testing.expect(t, ok, "EPA should succeed")
	testing.expect(t, abs(depth - 0.5) < 0.1, "EPA depth should be approximately 0.5")
	normal_length := abs(normal.x) + abs(normal.y) + abs(normal.z)
	testing.expect(t, abs(normal_length - 1.0) < 0.1, "Normal should be normalized")
}

@(test)
test_collision_gjk_sphere_sphere :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_sphere(1.0)
	collider_b := physics.collider_create_sphere(1.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	hit, point, normal, penetration := physics.test_collision_gjk(
		&collider_a,
		pos_a,
		&collider_b,
		pos_b,
	)
	testing.expect(t, hit, "Should detect collision")
	testing.expect(t, abs(penetration - 0.5) < 0.1, "Penetration should be approximately 0.5")
}

@(test)
test_collision_gjk_box_box :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_box({1, 1, 1})
	collider_b := physics.collider_create_box({1, 1, 1})
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{1.5, 0, 0}
	hit, point, normal, penetration := physics.test_collision_gjk(
		&collider_a,
		pos_a,
		&collider_b,
		pos_b,
	)
	testing.expect(t, hit, "Should detect collision")
	testing.expect(t, abs(penetration - 0.5) < 0.1, "Penetration should be approximately 0.5")
}

@(test)
test_support_function_sphere :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider := physics.collider_create_sphere(2.0)
	position := [3]f32{0, 0, 0}
	direction := [3]f32{1, 0, 0}
	point := physics.find_furthest_point(&collider, position, direction)
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
	testing.set_fail_timeout(t, 30 * time.Second)
	collider := physics.collider_create_box({1, 2, 3})
	position := [3]f32{0, 0, 0}
	direction := [3]f32{1, 1, 1}
	point := physics.find_furthest_point(&collider, position, direction)
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
test_support_function_capsule :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider := physics.collider_create_capsule(1.0, 4.0)
	position := [3]f32{0, 0, 0}
	direction := [3]f32{0, 1, 0}
	point := physics.find_furthest_point(&collider, position, direction)
	expected_y := f32(2.0 + 1.0)
	testing.expect(
		t,
		abs(point.y - expected_y) < 0.001,
		"Support function for capsule should return top hemisphere point",
	)
}
