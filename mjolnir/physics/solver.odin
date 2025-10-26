package physics

import "core:math/linalg"

resolve_contact :: proc(contact: ^Contact, body_a: ^RigidBody, body_b: ^RigidBody, pos_a: [3]f32, pos_b: [3]f32) {
	if body_a.is_static && body_b.is_static {
		return
	}
	inv_mass_sum := body_a.inv_mass + body_b.inv_mass
	if inv_mass_sum < 0.0001 {
		return
	}
	relative_velocity := body_b.velocity - body_a.velocity
	velocity_along_normal := linalg.vector_dot(relative_velocity, contact.normal)
	if velocity_along_normal > 0 {
		return
	}
	e := contact.restitution
	impulse_magnitude := -(1.0 + e) * velocity_along_normal / inv_mass_sum
	impulse := contact.normal * impulse_magnitude
	rigid_body_apply_impulse(body_a, -impulse)
	rigid_body_apply_impulse(body_b, impulse)
	tangent := relative_velocity - contact.normal * velocity_along_normal
	tangent_length_sq := linalg.vector_dot(tangent, tangent)
	if tangent_length_sq > 0.0001 {
		tangent = linalg.vector_normalize(tangent)
		friction_impulse_magnitude := -linalg.vector_dot(relative_velocity, tangent) / inv_mass_sum
		mu := contact.friction
		if abs(friction_impulse_magnitude) < abs(impulse_magnitude * mu) {
			friction_impulse := tangent * friction_impulse_magnitude
			rigid_body_apply_impulse(body_a, -friction_impulse)
			rigid_body_apply_impulse(body_b, friction_impulse)
		} else {
			friction_impulse := tangent * (-impulse_magnitude * mu)
			rigid_body_apply_impulse(body_a, -friction_impulse)
			rigid_body_apply_impulse(body_b, friction_impulse)
		}
	}
	percent :: 0.8
	slop :: 0.01
	correction_magnitude := max(contact.penetration - slop, 0.0) / inv_mass_sum * percent
	correction := contact.normal * correction_magnitude
	if !body_a.is_static {
		body_a.velocity -= correction * body_a.inv_mass
	}
	if !body_b.is_static {
		body_b.velocity += correction * body_b.inv_mass
	}
}
