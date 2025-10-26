package physics

import "core:math/linalg"
import "../resources"

RigidBody :: struct {
	node_handle:      resources.Handle,
	collider_handle:  resources.Handle,
	mass:             f32,
	inv_mass:         f32,
	inertia:          matrix[3, 3]f32,
	inv_inertia:      matrix[3, 3]f32,
	velocity:         [3]f32,
	angular_velocity: [3]f32,
	force:            [3]f32,
	torque:           [3]f32,
	restitution:      f32,
	friction:         f32,
	is_static:        bool,
	is_kinematic:     bool,
	gravity_scale:    f32,
}

rigid_body_create :: proc(
	node_handle: resources.Handle,
	mass: f32,
	is_static := false,
) -> RigidBody {
	body := RigidBody {
		node_handle   = node_handle,
		mass          = mass,
		inv_mass      = is_static ? 0.0 : 1.0 / mass,
		restitution   = 0.5,
		friction      = 0.5,
		is_static     = is_static,
		gravity_scale = 1.0,
	}
	if is_static {
		body.inertia = matrix[3, 3]f32{}
		body.inv_inertia = matrix[3, 3]f32{}
	} else {
		body.inertia = linalg.MATRIX3F32_IDENTITY
		body.inv_inertia = linalg.MATRIX3F32_IDENTITY
	}
	return body
}

rigid_body_set_box_inertia :: proc(body: ^RigidBody, half_extents: [3]f32) {
	if body.is_static {
		return
	}
	m := body.mass
	x2 := half_extents.x * half_extents.x
	y2 := half_extents.y * half_extents.y
	z2 := half_extents.z * half_extents.z
	body.inertia[0, 0] = (m / 3.0) * (y2 + z2)
	body.inertia[1, 1] = (m / 3.0) * (x2 + z2)
	body.inertia[2, 2] = (m / 3.0) * (x2 + y2)
	body.inv_inertia = linalg.matrix3_inverse_f32(body.inertia)
}

rigid_body_set_sphere_inertia :: proc(body: ^RigidBody, radius: f32) {
	if body.is_static {
		return
	}
	i := (2.0 / 5.0) * body.mass * radius * radius
	body.inertia[0, 0] = i
	body.inertia[1, 1] = i
	body.inertia[2, 2] = i
	body.inv_inertia = linalg.matrix3_inverse_f32(body.inertia)
}

rigid_body_set_capsule_inertia :: proc(body: ^RigidBody, radius: f32, height: f32) {
	if body.is_static {
		return
	}
	m := body.mass
	r2 := radius * radius
	h2 := height * height
	ix := (m / 12.0) * (3.0 * r2 + h2)
	iy := (m / 2.0) * r2
	body.inertia[0, 0] = ix
	body.inertia[1, 1] = iy
	body.inertia[2, 2] = ix
	body.inv_inertia = linalg.matrix3_inverse_f32(body.inertia)
}

rigid_body_apply_force :: proc(body: ^RigidBody, force: [3]f32) {
	if body.is_static {
		return
	}
	body.force += force
}

rigid_body_apply_force_at_point :: proc(
	body: ^RigidBody,
	force: [3]f32,
	point: [3]f32,
	center: [3]f32,
) {
	if body.is_static {
		return
	}
	body.force += force
	r := point - center
	body.torque += linalg.vector_cross3(r, force)
}

rigid_body_apply_impulse :: proc(body: ^RigidBody, impulse: [3]f32) {
	if body.is_static {
		return
	}
	body.velocity += impulse * body.inv_mass
}

rigid_body_apply_impulse_at_point :: proc(
	body: ^RigidBody,
	impulse: [3]f32,
	point: [3]f32,
	center: [3]f32,
) {
	if body.is_static {
		return
	}
	body.velocity += impulse * body.inv_mass
	r := point - center
	angular_impulse := linalg.vector_cross3(r, impulse)
	body.angular_velocity += linalg.matrix_mul_vector(body.inv_inertia, angular_impulse)
}

rigid_body_integrate :: proc(body: ^RigidBody, dt: f32) {
	if body.is_static || body.is_kinematic {
		return
	}
	body.velocity += body.force * body.inv_mass * dt
	body.angular_velocity += linalg.matrix_mul_vector(body.inv_inertia, body.torque) * dt
	body.force = {}
	body.torque = {}
}

rigid_body_clear_forces :: proc(body: ^RigidBody) {
	body.force = {}
	body.torque = {}
}
