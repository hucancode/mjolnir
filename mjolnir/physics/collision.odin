package physics

import "core:log"
import "core:math"
import "core:math/linalg"
import "../geometry"
import "../resources"

Contact :: struct {
	body_a:         resources.Handle,
	body_b:         resources.Handle,
	point:          [3]f32,
	normal:         [3]f32,
	penetration:    f32,
	restitution:    f32,
	friction:       f32,
}

CollisionPair :: struct {
	body_a: resources.Handle,
	body_b: resources.Handle,
}

test_sphere_sphere :: proc(
	pos_a: [3]f32,
	sphere_a: ^SphereCollider,
	pos_b: [3]f32,
	sphere_b: ^SphereCollider,
) -> (
	bool,
	[3]f32,
	[3]f32,
	f32,
) {
	delta := pos_b - pos_a
	distance_sq := linalg.vector_dot(delta, delta)
	radius_sum := sphere_a.radius + sphere_b.radius
	radius_sum_sq := radius_sum * radius_sum
	if distance_sq >= radius_sum_sq {
		return false, {}, {}, 0
	}
	distance := math.sqrt(distance_sq)
	normal: [3]f32
	if distance > 0.0001 {
		normal = delta / distance
	} else {
		normal = {0, 1, 0}
	}
	penetration := radius_sum - distance
	point := pos_a + normal * (sphere_a.radius - penetration * 0.5)
	return true, point, normal, penetration
}

test_box_box :: proc(
	pos_a: [3]f32,
	box_a: ^BoxCollider,
	pos_b: [3]f32,
	box_b: ^BoxCollider,
) -> (
	bool,
	[3]f32,
	[3]f32,
	f32,
) {
	min_a := pos_a - box_a.half_extents
	max_a := pos_a + box_a.half_extents
	min_b := pos_b - box_b.half_extents
	max_b := pos_b + box_b.half_extents
	if max_a.x < min_b.x || min_a.x > max_b.x {
		return false, {}, {}, 0
	}
	if max_a.y < min_b.y || min_a.y > max_b.y {
		return false, {}, {}, 0
	}
	if max_a.z < min_b.z || min_a.z > max_b.z {
		return false, {}, {}, 0
	}
	overlap_x := math.min(max_a.x, max_b.x) - math.max(min_a.x, min_b.x)
	overlap_y := math.min(max_a.y, max_b.y) - math.max(min_a.y, min_b.y)
	overlap_z := math.min(max_a.z, max_b.z) - math.max(min_a.z, min_b.z)
	min_overlap := min(overlap_x, overlap_y, overlap_z)
	normal: [3]f32
	if min_overlap == overlap_x {
		normal = pos_b.x > pos_a.x ? [3]f32{1, 0, 0} : [3]f32{-1, 0, 0}
	} else if min_overlap == overlap_y {
		normal = pos_b.y > pos_a.y ? [3]f32{0, 1, 0} : [3]f32{0, -1, 0}
	} else {
		normal = pos_b.z > pos_a.z ? [3]f32{0, 0, 1} : [3]f32{0, 0, -1}
	}
	point := (pos_a + pos_b) * 0.5
	return true, point, normal, min_overlap
}

test_sphere_box :: proc(
	pos_sphere: [3]f32,
	sphere: ^SphereCollider,
	pos_box: [3]f32,
	box: ^BoxCollider,
) -> (
	bool,
	[3]f32,
	[3]f32,
	f32,
) {
	min_box := pos_box - box.half_extents
	max_box := pos_box + box.half_extents
	closest := [3]f32 {
		clamp(pos_sphere.x, min_box.x, max_box.x),
		clamp(pos_sphere.y, min_box.y, max_box.y),
		clamp(pos_sphere.z, min_box.z, max_box.z),
	}
	delta := pos_sphere - closest
	distance_sq := linalg.vector_dot(delta, delta)
	radius_sq := sphere.radius * sphere.radius
	if distance_sq >= radius_sq {
		return false, {}, {}, 0
	}
	distance := math.sqrt(distance_sq)
	normal: [3]f32
	if distance > 0.0001 {
		normal = delta / distance
	} else {
		normal = {0, 1, 0}
	}
	penetration := sphere.radius - distance
	point := closest
	return true, point, normal, penetration
}

test_capsule_capsule :: proc(
	pos_a: [3]f32,
	capsule_a: ^CapsuleCollider,
	pos_b: [3]f32,
	capsule_b: ^CapsuleCollider,
) -> (
	bool,
	[3]f32,
	[3]f32,
	f32,
) {
	h_a := capsule_a.height * 0.5
	h_b := capsule_b.height * 0.5
	line_a_start := pos_a + [3]f32{0, -h_a, 0}
	line_a_end := pos_a + [3]f32{0, h_a, 0}
	line_b_start := pos_b + [3]f32{0, -h_b, 0}
	line_b_end := pos_b + [3]f32{0, h_b, 0}
	d1 := line_a_end - line_a_start
	d2 := line_b_end - line_b_start
	r := line_a_start - line_b_start
	a := linalg.vector_dot(d1, d1)
	e := linalg.vector_dot(d2, d2)
	f := linalg.vector_dot(d2, r)
	s, t: f32
	if a <= 0.0001 && e <= 0.0001 {
		s = 0
		t = 0
	} else if a <= 0.0001 {
		s = 0
		t = clamp(f / e, 0, 1)
	} else {
		c := linalg.vector_dot(d1, r)
		if e <= 0.0001 {
			t = 0
			s = clamp(-c / a, 0, 1)
		} else {
			b := linalg.vector_dot(d1, d2)
			denom := a * e - b * b
			if denom != 0 {
				s = clamp((b * f - c * e) / denom, 0, 1)
			} else {
				s = 0
			}
			t = (b * s + f) / e
			if t < 0 {
				t = 0
				s = clamp(-c / a, 0, 1)
			} else if t > 1 {
				t = 1
				s = clamp((b - c) / a, 0, 1)
			}
		}
	}
	point_a := line_a_start + d1 * s
	point_b := line_b_start + d2 * t
	delta := point_b - point_a
	distance_sq := linalg.vector_dot(delta, delta)
	radius_sum := capsule_a.radius + capsule_b.radius
	radius_sum_sq := radius_sum * radius_sum
	if distance_sq >= radius_sum_sq {
		return false, {}, {}, 0
	}
	distance := math.sqrt(distance_sq)
	normal: [3]f32
	if distance > 0.0001 {
		normal = delta / distance
	} else {
		normal = {0, 1, 0}
	}
	penetration := radius_sum - distance
	point := point_a + normal * (capsule_a.radius - penetration * 0.5)
	return true, point, normal, penetration
}

test_sphere_capsule :: proc(
	pos_sphere: [3]f32,
	sphere: ^SphereCollider,
	pos_capsule: [3]f32,
	capsule: ^CapsuleCollider,
) -> (
	bool,
	[3]f32,
	[3]f32,
	f32,
) {
	h := capsule.height * 0.5
	line_start := pos_capsule + [3]f32{0, -h, 0}
	line_end := pos_capsule + [3]f32{0, h, 0}
	line_dir := line_end - line_start
	line_length_sq := linalg.vector_dot(line_dir, line_dir)
	t: f32
	if line_length_sq < 0.0001 {
		t = 0
	} else {
		t = clamp(linalg.vector_dot(pos_sphere - line_start, line_dir) / line_length_sq, 0, 1)
	}
	closest := line_start + line_dir * t
	delta := pos_sphere - closest
	distance_sq := linalg.vector_dot(delta, delta)
	radius_sum := sphere.radius + capsule.radius
	radius_sum_sq := radius_sum * radius_sum
	if distance_sq >= radius_sum_sq {
		return false, {}, {}, 0
	}
	distance := math.sqrt(distance_sq)
	normal: [3]f32
	if distance > 0.0001 {
		normal = delta / distance
	} else {
		normal = {0, 1, 0}
	}
	penetration := radius_sum - distance
	point := closest + normal * (capsule.radius - penetration * 0.5)
	return true, point, normal, penetration
}

test_box_capsule :: proc(
	pos_box: [3]f32,
	box: ^BoxCollider,
	pos_capsule: [3]f32,
	capsule: ^CapsuleCollider,
) -> (
	bool,
	[3]f32,
	[3]f32,
	f32,
) {
	h := capsule.height * 0.5
	line_start := pos_capsule + [3]f32{0, -h, 0}
	line_end := pos_capsule + [3]f32{0, h, 0}
	min_box := pos_box - box.half_extents
	max_box := pos_box + box.half_extents
	closest_start := [3]f32 {
		clamp(line_start.x, min_box.x, max_box.x),
		clamp(line_start.y, min_box.y, max_box.y),
		clamp(line_start.z, min_box.z, max_box.z),
	}
	closest_end := [3]f32 {
		clamp(line_end.x, min_box.x, max_box.x),
		clamp(line_end.y, min_box.y, max_box.y),
		clamp(line_end.z, min_box.z, max_box.z),
	}
	dist_start_sq := linalg.vector_dot(line_start - closest_start, line_start - closest_start)
	dist_end_sq := linalg.vector_dot(line_end - closest_end, line_end - closest_end)
	radius_sq := capsule.radius * capsule.radius
	closest: [3]f32
	point_on_line: [3]f32
	if dist_start_sq < dist_end_sq {
		closest = closest_start
		point_on_line = line_start
	} else {
		closest = closest_end
		point_on_line = line_end
	}
	delta := point_on_line - closest
	distance_sq := linalg.vector_dot(delta, delta)
	if distance_sq >= radius_sq {
		return false, {}, {}, 0
	}
	distance := math.sqrt(distance_sq)
	normal: [3]f32
	if distance > 0.0001 {
		normal = delta / distance
	} else {
		normal = {0, 1, 0}
	}
	penetration := capsule.radius - distance
	point := closest
	return true, point, normal, penetration
}

test_collision :: proc(
	collider_a: ^Collider,
	pos_a: [3]f32,
	collider_b: ^Collider,
	pos_b: [3]f32,
) -> (
	bool,
	[3]f32,
	[3]f32,
	f32,
) {
	center_a := pos_a + collider_a.offset
	center_b := pos_b + collider_b.offset
	if collider_a.type == .Sphere && collider_b.type == .Sphere {
		sphere_a := &collider_a.shape.(SphereCollider)
		sphere_b := &collider_b.shape.(SphereCollider)
		return test_sphere_sphere(center_a, sphere_a, center_b, sphere_b)
	} else if collider_a.type == .Box && collider_b.type == .Box {
		box_a := &collider_a.shape.(BoxCollider)
		box_b := &collider_b.shape.(BoxCollider)
		return test_box_box(center_a, box_a, center_b, box_b)
	} else if collider_a.type == .Sphere && collider_b.type == .Box {
		sphere := &collider_a.shape.(SphereCollider)
		box := &collider_b.shape.(BoxCollider)
		return test_sphere_box(center_a, sphere, center_b, box)
	} else if collider_a.type == .Box && collider_b.type == .Sphere {
		box := &collider_a.shape.(BoxCollider)
		sphere := &collider_b.shape.(SphereCollider)
		hit, point, normal, penetration := test_sphere_box(center_b, sphere, center_a, box)
		return hit, point, -normal, penetration
	} else if collider_a.type == .Capsule && collider_b.type == .Capsule {
		capsule_a := &collider_a.shape.(CapsuleCollider)
		capsule_b := &collider_b.shape.(CapsuleCollider)
		return test_capsule_capsule(center_a, capsule_a, center_b, capsule_b)
	} else if collider_a.type == .Sphere && collider_b.type == .Capsule {
		sphere := &collider_a.shape.(SphereCollider)
		capsule := &collider_b.shape.(CapsuleCollider)
		return test_sphere_capsule(center_a, sphere, center_b, capsule)
	} else if collider_a.type == .Capsule && collider_b.type == .Sphere {
		capsule := &collider_a.shape.(CapsuleCollider)
		sphere := &collider_b.shape.(SphereCollider)
		hit, point, normal, penetration := test_sphere_capsule(center_b, sphere, center_a, capsule)
		return hit, point, -normal, penetration
	} else if collider_a.type == .Box && collider_b.type == .Capsule {
		box := &collider_a.shape.(BoxCollider)
		capsule := &collider_b.shape.(CapsuleCollider)
		return test_box_capsule(center_a, box, center_b, capsule)
	} else if collider_a.type == .Capsule && collider_b.type == .Box {
		capsule := &collider_a.shape.(CapsuleCollider)
		box := &collider_b.shape.(BoxCollider)
		hit, point, normal, penetration := test_box_capsule(center_b, box, center_a, capsule)
		return hit, point, -normal, penetration
	}
	return false, {}, {}, 0
}
