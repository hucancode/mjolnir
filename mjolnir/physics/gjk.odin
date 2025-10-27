package physics

import "core:math"
import "core:math/linalg"

// Support function: finds the furthest point in a given direction
// This is the core of GJK - it queries both shapes and returns a point in Minkowski space
support :: proc(
	collider_a: ^Collider,
	pos_a: [3]f32,
	collider_b: ^Collider,
	pos_b: [3]f32,
	direction: [3]f32,
) -> [3]f32 {
	point_a := find_furthest_point(collider_a, pos_a, direction)
	point_b := find_furthest_point(collider_b, pos_b, -direction)
	return point_a - point_b
}

// Find the furthest point on a collider in a given direction
find_furthest_point :: proc(
	collider: ^Collider,
	position: [3]f32,
	direction: [3]f32,
) -> [3]f32 {
	center := position + collider.offset
	switch collider.type {
	case .Sphere:
		sphere := collider.shape.(SphereCollider)
		dir_normalized := linalg.normalize0(direction)
		return center + dir_normalized * sphere.radius
	case .Box:
		box := collider.shape.(BoxCollider)
		// For a box, the furthest point is one of the 8 vertices
		sign_x := direction.x >= 0 ? f32(1.0) : f32(-1.0)
		sign_y := direction.y >= 0 ? f32(1.0) : f32(-1.0)
		sign_z := direction.z >= 0 ? f32(1.0) : f32(-1.0)
		return center + [3]f32 {
			box.half_extents.x * sign_x,
			box.half_extents.y * sign_y,
			box.half_extents.z * sign_z,
		}
	case .Capsule:
		capsule := collider.shape.(CapsuleCollider)
		h := capsule.height * 0.5
		// Capsule is two hemispheres connected by a cylinder
		// First find the furthest point on the central line segment
		line_dir := [3]f32{0, 1, 0}
		dot := linalg.vector_dot(direction, line_dir)
		line_point := center + line_dir * (dot >= 0 ? h : -h)
		// Then add the sphere radius in the direction
		dir_normalized := linalg.normalize0(direction)
		return line_point + dir_normalized * capsule.radius
	}
	return center
}

// Simplex for 3D GJK - can be a point, line, triangle, or tetrahedron
Simplex :: struct {
	points: [4][3]f32,
	count:  int,
}

simplex_push_front :: proc(s: ^Simplex, point: [3]f32) {
	s.count = min(s.count + 1, 4)
	// Shift existing points back
	for i := s.count - 1; i > 0; i -= 1 {
		s.points[i] = s.points[i - 1]
	}
	s.points[0] = point
}

simplex_set :: proc(s: ^Simplex, points: ..[3]f32) {
	s.count = len(points)
	for i in 0 ..< s.count {
		s.points[i] = points[i]
	}
}

// GJK algorithm - returns true if shapes collide
gjk :: proc(
	collider_a: ^Collider,
	pos_a: [3]f32,
	collider_b: ^Collider,
	pos_b: [3]f32,
	simplex_out: ^Simplex,
) -> bool {
	// Initial direction (from B to A)
	direction := pos_a - pos_b
	if linalg.vector_dot(direction, direction) < 0.0001 {
		direction = {1, 0, 0}
	}

	// Get first point
	simplex := Simplex{}
	simplex_push_front(&simplex, support(collider_a, pos_a, collider_b, pos_b, direction))

	// Reverse direction
	direction = -simplex.points[0]

	max_iterations := 32
	for iteration in 0 ..< max_iterations {
		a := support(collider_a, pos_a, collider_b, pos_b, direction)

		// If we didn't pass the origin, there's no collision
		if linalg.vector_dot(a, direction) < 0 {
			return false
		}

		simplex_push_front(&simplex, a)

		// Check if simplex contains origin and update it
		if next_simplex(&simplex, &direction) {
			if simplex_out != nil {
				simplex_out^ = simplex
			}
			return true
		}
	}

	return false
}

// Determines if simplex contains origin and updates direction
next_simplex :: proc(simplex: ^Simplex, direction: ^[3]f32) -> bool {
	switch simplex.count {
	case 2:
		return line_case(simplex, direction)
	case 3:
		return triangle_case(simplex, direction)
	case 4:
		return tetrahedron_case(simplex, direction)
	}
	return false
}

// Check if line segment contains origin
line_case :: proc(simplex: ^Simplex, direction: ^[3]f32) -> bool {
	a := simplex.points[0]
	b := simplex.points[1]

	ab := b - a
	ao := -a

	// If origin is in the direction of AB
	if same_direction(ab, ao) {
		ab_ao := linalg.vector_cross3(ab, ao)
		new_dir := linalg.vector_cross3(ab_ao, ab)
		// Safety check for zero-length direction
		if linalg.length(new_dir) < 0.0001 {
			direction^ = ao
		} else {
			direction^ = new_dir
		}
	} else {
		// Origin is closer to A
		simplex_set(simplex, a)
		direction^ = ao
	}

	return false
}

// Check if triangle contains origin
triangle_case :: proc(simplex: ^Simplex, direction: ^[3]f32) -> bool {
	a := simplex.points[0]
	b := simplex.points[1]
	c := simplex.points[2]

	ab := b - a
	ac := c - a
	ao := -a

	abc := linalg.vector_cross3(ab, ac)

	// Check if origin is outside edge AC
	if same_direction(linalg.vector_cross3(abc, ac), ao) {
		if same_direction(ac, ao) {
			simplex_set(simplex, a, c)
			ac_ao := linalg.vector_cross3(ac, ao)
			new_dir := linalg.vector_cross3(ac_ao, ac)
			// Safety check for zero-length direction
			if linalg.length(new_dir) < 0.0001 {
				direction^ = ao
			} else {
				direction^ = new_dir
			}
		} else {
			return line_case(simplex, direction)
		}
	} else {
		// Check if origin is outside edge AB
		if same_direction(linalg.vector_cross3(ab, abc), ao) {
			return line_case(simplex, direction)
		} else {
			// Origin is either above or below the triangle
			if same_direction(abc, ao) {
				direction^ = abc
			} else {
				simplex_set(simplex, a, c, b)
				direction^ = -abc
			}
		}
	}

	return false
}

// Check if tetrahedron contains origin
tetrahedron_case :: proc(simplex: ^Simplex, direction: ^[3]f32) -> bool {
	a := simplex.points[0]
	b := simplex.points[1]
	c := simplex.points[2]
	d := simplex.points[3]

	ab := b - a
	ac := c - a
	ad := d - a
	ao := -a

	abc := linalg.vector_cross3(ab, ac)
	acd := linalg.vector_cross3(ac, ad)
	adb := linalg.vector_cross3(ad, ab)

	// Check each face
	if same_direction(abc, ao) {
		simplex_set(simplex, a, b, c)
		return triangle_case(simplex, direction)
	}

	if same_direction(acd, ao) {
		simplex_set(simplex, a, c, d)
		return triangle_case(simplex, direction)
	}

	if same_direction(adb, ao) {
		simplex_set(simplex, a, d, b)
		return triangle_case(simplex, direction)
	}

	// Origin is inside tetrahedron
	return true
}

// Check if two vectors point in the same direction
same_direction :: proc(a, b: [3]f32) -> bool {
	return linalg.vector_dot(a, b) > 0
}
