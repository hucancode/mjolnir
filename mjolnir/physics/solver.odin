package physics

import "core:math/linalg"

resolve_contact :: proc(contact: ^Contact, body_a: ^RigidBody, body_b: ^RigidBody, pos_a: [3]f32, pos_b: [3]f32) {
	if body_a.is_static && body_b.is_static {
		return
	}

	// Calculate contact points relative to body centers
	r_a := contact.point - pos_a
	r_b := contact.point - pos_b

	// Calculate relative velocity at contact point including angular velocity
	vel_a := body_a.velocity + linalg.vector_cross3(body_a.angular_velocity, r_a)
	vel_b := body_b.velocity + linalg.vector_cross3(body_b.angular_velocity, r_b)
	relative_velocity := vel_b - vel_a

	// Velocity along normal
	velocity_along_normal := linalg.vector_dot(relative_velocity, contact.normal)

	// Already separating
	if velocity_along_normal > 0 {
		return
	}

	// Calculate impulse denominator including angular effects
	r_a_cross_n := linalg.vector_cross3(r_a, contact.normal)
	r_b_cross_n := linalg.vector_cross3(r_b, contact.normal)

	inv_mass_sum := body_a.inv_mass + body_b.inv_mass
	angular_factor_a := linalg.vector_dot(
		linalg.matrix_mul_vector(body_a.inv_inertia, r_a_cross_n),
		r_a_cross_n,
	)
	angular_factor_b := linalg.vector_dot(
		linalg.matrix_mul_vector(body_b.inv_inertia, r_b_cross_n),
		r_b_cross_n,
	)

	impulse_denominator := inv_mass_sum + angular_factor_a + angular_factor_b

	if impulse_denominator < 0.0001 {
		return
	}

	// Calculate impulse magnitude with restitution
	e := contact.restitution
	impulse_magnitude := -(1.0 + e) * velocity_along_normal / impulse_denominator
	impulse := contact.normal * impulse_magnitude

	// Apply impulse at contact point
	rigid_body_apply_impulse_at_point(body_a, -impulse, contact.point, pos_a)
	rigid_body_apply_impulse_at_point(body_b, impulse, contact.point, pos_b)

	// Friction
	// Recalculate relative velocity after normal impulse
	vel_a = body_a.velocity + linalg.vector_cross3(body_a.angular_velocity, r_a)
	vel_b = body_b.velocity + linalg.vector_cross3(body_b.angular_velocity, r_b)
	relative_velocity = vel_b - vel_a

	// Tangent velocity (perpendicular to normal)
	tangent := relative_velocity - contact.normal * linalg.vector_dot(relative_velocity, contact.normal)
	tangent_length_sq := linalg.vector_dot(tangent, tangent)

	if tangent_length_sq > 0.0001 {
		tangent = linalg.vector_normalize(tangent)

		// Calculate friction impulse denominator
		r_a_cross_t := linalg.vector_cross3(r_a, tangent)
		r_b_cross_t := linalg.vector_cross3(r_b, tangent)

		angular_factor_a_friction := linalg.vector_dot(
			linalg.matrix_mul_vector(body_a.inv_inertia, r_a_cross_t),
			r_a_cross_t,
		)
		angular_factor_b_friction := linalg.vector_dot(
			linalg.matrix_mul_vector(body_b.inv_inertia, r_b_cross_t),
			r_b_cross_t,
		)

		friction_denominator := inv_mass_sum + angular_factor_a_friction + angular_factor_b_friction

		if friction_denominator > 0.0001 {
			friction_impulse_magnitude := -linalg.vector_dot(relative_velocity, tangent) / friction_denominator
			mu := contact.friction

			// Coulomb friction
			if abs(friction_impulse_magnitude) < abs(impulse_magnitude * mu) {
				friction_impulse := tangent * friction_impulse_magnitude
				rigid_body_apply_impulse_at_point(body_a, -friction_impulse, contact.point, pos_a)
				rigid_body_apply_impulse_at_point(body_b, friction_impulse, contact.point, pos_b)
			} else {
				friction_impulse := tangent * (-impulse_magnitude * mu)
				rigid_body_apply_impulse_at_point(body_a, -friction_impulse, contact.point, pos_a)
				rigid_body_apply_impulse_at_point(body_b, friction_impulse, contact.point, pos_b)
			}
		}
	}

	// Position correction (Baumgarte stabilization)
	// This is intentionally applied as velocity to avoid jitter
	percent :: 0.2
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

// Direct position correction to prevent sinking
resolve_contact_position :: proc(contact: ^Contact, body_a: ^RigidBody, body_b: ^RigidBody, pos_a: ^[3]f32, pos_b: ^[3]f32) {
	if body_a.is_static && body_b.is_static {
		return
	}

	inv_mass_sum := body_a.inv_mass + body_b.inv_mass
	if inv_mass_sum < 0.0001 {
		return
	}

	// Apply position correction directly, but gently
	percent :: 0.4  // Reduced from 0.8 - spread correction over more iterations
	slop :: 0.01
	max_correction :: 0.2  // Clamp to prevent violent bounces

	penetration_to_resolve := max(contact.penetration - slop, 0.0)
	correction_magnitude := min(penetration_to_resolve / inv_mass_sum * percent, max_correction)
	correction := contact.normal * correction_magnitude

	if !body_a.is_static {
		pos_a^ -= correction * body_a.inv_mass
	}
	if !body_b.is_static {
		pos_b^ += correction * body_b.inv_mass
	}
}
