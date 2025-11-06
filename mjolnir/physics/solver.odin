package physics

import "core:math/linalg"

// Prepare contact constraint for solving (called once before iterations)
prepare_contact :: proc(
  contact: ^Contact,
  body_a: ^RigidBody,
  body_b: ^RigidBody,
  pos_a: [3]f32,
  pos_b: [3]f32,
  dt: f32,
) {
  r_a := contact.point - pos_a
  r_b := contact.point - pos_b
  r_a_cross_n := linalg.cross(r_a, contact.normal)
  r_b_cross_n := linalg.cross(r_b, contact.normal)
  inv_mass_sum := body_a.inv_mass + body_b.inv_mass
  angular_factor_a := linalg.dot(
    body_a.inv_inertia * r_a_cross_n,
    r_a_cross_n,
  )
  angular_factor_b := linalg.dot(
    body_b.inv_inertia * r_b_cross_n,
    r_b_cross_n,
  )
  normal_mass := inv_mass_sum + angular_factor_a + angular_factor_b
  if normal_mass > 0.0001 {
    contact.normal_mass = 1.0 / normal_mass
  } else {
    contact.normal_mass = 0
  }
  tangent1, tangent2 := compute_tangent_basis(contact.normal)
  for i in 0 ..< 2 {
    tangent := i == 0 ? tangent1 : tangent2
    r_a_cross_t := linalg.cross(r_a, tangent)
    r_b_cross_t := linalg.cross(r_b, tangent)
    angular_factor_a_t := linalg.dot(
      body_a.inv_inertia * r_a_cross_t,
      r_a_cross_t,
    )
    angular_factor_b_t := linalg.dot(
      body_b.inv_inertia * r_b_cross_t,
      r_b_cross_t,
    )
    tangent_mass := inv_mass_sum + angular_factor_a_t + angular_factor_b_t
    if tangent_mass > 0.0001 {
      contact.tangent_mass[i] = 1.0 / tangent_mass
    } else {
      contact.tangent_mass[i] = 0
    }
  }
  baumgarte_coef :: 0.15
  slop :: 0.002
  penetration_to_resolve := max(contact.penetration - slop, 0.0)
  contact.bias = (baumgarte_coef / dt) * penetration_to_resolve
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, r_a)
  vel_b := body_b.velocity + linalg.cross(body_b.angular_velocity, r_b)
  relative_velocity := vel_b - vel_a
  velocity_along_normal := linalg.dot(relative_velocity, contact.normal)
  restitution_threshold :: -0.5
  if velocity_along_normal < restitution_threshold {
    contact.bias += -contact.restitution * velocity_along_normal
  }
}

// Warmstart contact with cached impulses (improves convergence)
warmstart_contact :: proc(
  contact: ^Contact,
  body_a: ^RigidBody,
  body_b: ^RigidBody,
  pos_a: [3]f32,
  pos_b: [3]f32,
) {
  if body_a.is_static && body_b.is_static {
    return
  }
  r_a := contact.point - pos_a
  r_b := contact.point - pos_b
  impulse_n := contact.normal * contact.normal_impulse
  rigid_body_apply_impulse_at_point(body_a, -impulse_n, contact.point, pos_a)
  rigid_body_apply_impulse_at_point(body_b, impulse_n, contact.point, pos_b)
  tangent1, tangent2 := compute_tangent_basis(contact.normal)
  tangents := [2][3]f32{tangent1, tangent2}
  for i in 0 ..< 2 {
    impulse_t := tangents[i] * contact.tangent_impulse[i]
    rigid_body_apply_impulse_at_point(body_a, -impulse_t, contact.point, pos_a)
    rigid_body_apply_impulse_at_point(body_b, impulse_t, contact.point, pos_b)
  }
}

// Solve contact constraint using Sequential Impulse method
resolve_contact :: proc(
  contact: ^Contact,
  body_a: ^RigidBody,
  body_b: ^RigidBody,
  pos_a: [3]f32,
  pos_b: [3]f32,
) {
  if body_a.is_static && body_b.is_static {
    return
  }
  r_a := contact.point - pos_a
  r_b := contact.point - pos_b
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, r_a)
  vel_b := body_b.velocity + linalg.cross(body_b.angular_velocity, r_b)
  relative_velocity := vel_b - vel_a
  velocity_along_normal := linalg.dot(relative_velocity, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal + contact.bias)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  delta_impulse = contact.normal_impulse - old_impulse
  impulse := contact.normal * delta_impulse
  rigid_body_apply_impulse_at_point(body_a, -impulse, contact.point, pos_a)
  rigid_body_apply_impulse_at_point(body_b, impulse, contact.point, pos_b)
  tangent1, tangent2 := compute_tangent_basis(contact.normal)
  tangents := [2][3]f32{tangent1, tangent2}
  max_friction := contact.friction * contact.normal_impulse
  for i in 0 ..< 2 {
    vel_a = body_a.velocity + linalg.cross(body_a.angular_velocity, r_a)
    vel_b = body_b.velocity + linalg.cross(body_b.angular_velocity, r_b)
    velocity_along_tangent := linalg.dot(vel_b - vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    rigid_body_apply_impulse_at_point(body_a, -impulse_t, contact.point, pos_a)
    rigid_body_apply_impulse_at_point(body_b, impulse_t, contact.point, pos_b)
  }
}

resolve_contact_no_bias :: proc(
  contact: ^Contact,
  body_a: ^RigidBody,
  body_b: ^RigidBody,
  pos_a: [3]f32,
  pos_b: [3]f32,
) {
  if body_a.is_static && body_b.is_static {
    return
  }
  r_a := contact.point - pos_a
  r_b := contact.point - pos_b
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, r_a)
  vel_b := body_b.velocity + linalg.cross(body_b.angular_velocity, r_b)
  velocity_along_normal := linalg.dot(vel_b - vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  impulse := contact.normal * (contact.normal_impulse - old_impulse)
  rigid_body_apply_impulse_at_point(body_a, -impulse, contact.point, pos_a)
  rigid_body_apply_impulse_at_point(body_b, impulse, contact.point, pos_b)
  tangent1, tangent2 := compute_tangent_basis(contact.normal)
  tangents := [2][3]f32{tangent1, tangent2}
  max_friction := contact.friction * contact.normal_impulse
  for i in 0 ..< 2 {
    vel_a = body_a.velocity + linalg.cross(body_a.angular_velocity, r_a)
    vel_b = body_b.velocity + linalg.cross(body_b.angular_velocity, r_b)
    velocity_along_tangent := linalg.dot(vel_b - vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    rigid_body_apply_impulse_at_point(body_a, -impulse_t, contact.point, pos_a)
    rigid_body_apply_impulse_at_point(body_b, impulse_t, contact.point, pos_b)
  }
}

compute_tangent_basis :: proc(normal: [3]f32) -> ([3]f32, [3]f32) {
  tangent1 := linalg.normalize(linalg.vector3_orthogonal(normal))
  tangent2 := linalg.cross(normal, tangent1)
  return tangent1, tangent2
}
