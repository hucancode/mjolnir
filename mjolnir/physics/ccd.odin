package physics

import "core:math"
import "core:math/linalg"

// Time of Impact result
TOIResult :: struct {
	has_impact: bool,
	time:       f32, // 0.0 to 1.0 (fraction of motion)
	normal:     [3]f32,
	point:      [3]f32,
}

// Swept sphere vs static sphere
swept_sphere_sphere :: proc(
	center_a: [3]f32,
	radius_a: f32,
	velocity_a: [3]f32,
	center_b: [3]f32,
	radius_b: f32,
) -> TOIResult {
	result := TOIResult{}

	// Relative motion
	motion := velocity_a
	motion_length_sq := linalg.vector_dot(motion, motion)

	if motion_length_sq < 0.0001 {
		// Not moving - use discrete test
		delta := center_b - center_a
		distance_sq := linalg.vector_dot(delta, delta)
		radius_sum := radius_a + radius_b
		if distance_sq < radius_sum * radius_sum {
			result.has_impact = true
			result.time = 0.0
			distance := math.sqrt(distance_sq)
			result.normal = distance > 0.0001 ? delta / distance : [3]f32{0, 1, 0}
			result.point = center_a + result.normal * radius_a
		}
		return result
	}

	// Solve quadratic: |center_a + t*velocity - center_b|^2 = (radius_a + radius_b)^2
	// Let d = center_a - center_b
	// (d + t*v)·(d + t*v) = r^2
	// v·v*t^2 + 2*d·v*t + d·d - r^2 = 0

	d := center_a - center_b
	radius_sum := radius_a + radius_b

	a := motion_length_sq
	b := 2.0 * linalg.vector_dot(d, motion)
	c := linalg.vector_dot(d, d) - radius_sum * radius_sum

	discriminant := b * b - 4.0 * a * c

	if discriminant < 0 {
		// No intersection
		return result
	}

	// Take earlier root (first impact)
	sqrt_disc := math.sqrt(discriminant)
	t1 := (-b - sqrt_disc) / (2.0 * a)
	t2 := (-b + sqrt_disc) / (2.0 * a)

	// We want the first impact in the range [0, 1]
	t := t1
	if t < 0 {
		t = t2
	}

	if t >= 0 && t <= 1.0 {
		result.has_impact = true
		result.time = t
		impact_center_a := center_a + motion * t
		delta := center_b - impact_center_a
		distance := linalg.vector_length(delta)
		result.normal = distance > 0.0001 ? delta / distance : [3]f32{0, 1, 0}
		result.point = impact_center_a + result.normal * radius_a
	}

	return result
}

// Swept sphere vs static box (AABB)
swept_sphere_box :: proc(
	center: [3]f32,
	radius: f32,
	velocity: [3]f32,
	box_min: [3]f32,
	box_max: [3]f32,
) -> TOIResult {
	result := TOIResult{}

	// Expand the box by sphere radius - now ray vs expanded box
	expanded_min := box_min - [3]f32{radius, radius, radius}
	expanded_max := box_max + [3]f32{radius, radius, radius}

	// Ray-AABB intersection (Slab method)
	t_min := f32(-1e6)
	t_max := f32(1e6)
	hit_normal := [3]f32{0, 1, 0}

	for i in 0 ..< 3 {
		if abs(velocity[i]) < 0.0001 {
			// Ray parallel to slab
			if center[i] < expanded_min[i] || center[i] > expanded_max[i] {
				return result // No hit
			}
		} else {
			// Compute intersection with slab
			inv_d := 1.0 / velocity[i]
			t1 := (expanded_min[i] - center[i]) * inv_d
			t2 := (expanded_max[i] - center[i]) * inv_d

			// Determine which is near/far
			if t1 > t2 {
				t1, t2 = t2, t1
			}

			// Update intervals
			if t1 > t_min {
				t_min = t1
				// Normal points from box to sphere
				hit_normal = {}
				hit_normal[i] = velocity[i] > 0 ? -1.0 : 1.0
			}
			if t2 < t_max {
				t_max = t2
			}

			// Early exit if no overlap
			if t_min > t_max {
				return result
			}
		}
	}

	// Check if impact is in valid range [0, 1]
	if t_min >= 0 && t_min <= 1.0 {
		result.has_impact = true
		result.time = t_min
		result.normal = hit_normal
		result.point = center + velocity * t_min
	}

	return result
}

// Swept test dispatcher
swept_test :: proc(
	collider_a: ^Collider,
	pos_a: [3]f32,
	velocity_a: [3]f32,
	collider_b: ^Collider,
	pos_b: [3]f32,
) -> TOIResult {
	center_a := pos_a + collider_a.offset
	center_b := pos_b + collider_b.offset

	// For now, implement sphere-sphere and sphere-box
	// Can extend to other shapes later
	if collider_a.type == .Sphere && collider_b.type == .Sphere {
		sphere_a := collider_a.shape.(SphereCollider)
		sphere_b := collider_b.shape.(SphereCollider)
		return swept_sphere_sphere(center_a, sphere_a.radius, velocity_a, center_b, sphere_b.radius)
	}

	if collider_a.type == .Sphere && collider_b.type == .Box {
		sphere := collider_a.shape.(SphereCollider)
		box := collider_b.shape.(BoxCollider)
		box_min := center_b - box.half_extents
		box_max := center_b + box.half_extents
		return swept_sphere_box(center_a, sphere.radius, velocity_a, box_min, box_max)
	}

	if collider_a.type == .Box && collider_b.type == .Sphere {
		// Swap and negate velocity
		sphere := collider_b.shape.(SphereCollider)
		box := collider_a.shape.(BoxCollider)
		box_min := center_a - box.half_extents
		box_max := center_a + box.half_extents
		result := swept_sphere_box(center_b, sphere.radius, -velocity_a, box_min, box_max)
		if result.has_impact {
			result.normal = -result.normal
		}
		return result
	}

	// Fallback: no swept test available
	return TOIResult{}
}
