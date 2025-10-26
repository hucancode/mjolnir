package tests

import "core:math"
import "core:testing"
import "core:time"
import "../mjolnir/physics"

@(test)
test_swept_sphere_sphere_hit :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	// Sphere moving right toward stationary sphere
	center_a := [3]f32{0, 0, 0}
	radius_a := f32(1.0)
	velocity := [3]f32{10, 0, 0} // Moving fast
	center_b := [3]f32{5, 0, 0}
	radius_b := f32(1.0)

	result := physics.swept_sphere_sphere(center_a, radius_a, velocity, center_b, radius_b)

	testing.expect(t, result.has_impact, "Should detect impact")
	// Should hit at distance 5 - 2 = 3, so t = 3/10 = 0.3
	testing.expect(t, abs(result.time - 0.3) < 0.01, "TOI should be approximately 0.3")
	testing.expect(t, abs(result.normal.x - 1.0) < 0.01, "Normal should point right")
}

@(test)
test_swept_sphere_sphere_miss :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	// Sphere moving parallel, not hitting
	center_a := [3]f32{0, 0, 0}
	radius_a := f32(1.0)
	velocity := [3]f32{10, 0, 0}
	center_b := [3]f32{5, 5, 0} // Too far away
	radius_b := f32(1.0)

	result := physics.swept_sphere_sphere(center_a, radius_a, velocity, center_b, radius_b)

	testing.expect(t, !result.has_impact, "Should not detect impact")
}

@(test)
test_swept_sphere_sphere_already_touching :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	// Spheres already touching at t=0
	center_a := [3]f32{0, 0, 0}
	radius_a := f32(1.0)
	velocity := [3]f32{1, 0, 0}
	center_b := [3]f32{2, 0, 0} // Exactly touching
	radius_b := f32(1.0)

	result := physics.swept_sphere_sphere(center_a, radius_a, velocity, center_b, radius_b)

	testing.expect(t, result.has_impact, "Should detect impact")
	testing.expect(t, result.time < 0.01, "TOI should be at start")
}

@(test)
test_swept_sphere_box_hit :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	// Sphere moving toward box
	center := [3]f32{0, 0, 0}
	radius := f32(1.0)
	velocity := [3]f32{10, 0, 0}
	box_min := [3]f32{4, -1, -1}
	box_max := [3]f32{6, 1, 1}

	result := physics.swept_sphere_box(center, radius, velocity, box_min, box_max)

	testing.expect(t, result.has_impact, "Should detect impact with box")
	// Expanded box starts at 4-1=3, so hit at t = 3/10 = 0.3
	testing.expect(t, abs(result.time - 0.3) < 0.01, "TOI should be approximately 0.3")
}

@(test)
test_swept_sphere_box_miss :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	// Sphere moving away from box
	center := [3]f32{0, 0, 0}
	radius := f32(1.0)
	velocity := [3]f32{-10, 0, 0}
	box_min := [3]f32{4, -1, -1}
	box_max := [3]f32{6, 1, 1}

	result := physics.swept_sphere_box(center, radius, velocity, box_min, box_max)

	testing.expect(t, !result.has_impact, "Should not hit box when moving away")
}

@(test)
test_swept_collider_sphere_sphere :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	collider_a := physics.collider_create_sphere(1.0)
	collider_b := physics.collider_create_sphere(1.0)
	pos_a := [3]f32{0, 0, 0}
	pos_b := [3]f32{5, 0, 0}
	velocity := [3]f32{10, 0, 0}

	result := physics.swept_test(&collider_a, pos_a, velocity, &collider_b, pos_b)

	testing.expect(t, result.has_impact, "Swept test should detect collision")
	testing.expect(t, result.time > 0 && result.time < 1.0, "TOI should be in valid range")
}
