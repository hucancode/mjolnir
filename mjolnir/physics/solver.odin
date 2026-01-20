package physics

import "core:math"
import "core:log"
import "core:math/linalg"

BAUMGARTE_COEF :: 0.4
SLOP :: 0.002
RESTITUTION_THRESHOLD :: -0.5

prepare_contact_dynamic_dynamic :: proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
  dt: f32,
) {
  contact.r_a = contact.point - body_a.position
  contact.r_b = contact.point - body_b.position
  r_a_cross_n := vector_cross3(contact.r_a, contact.normal)
  r_b_cross_n := vector_cross3(contact.r_b, contact.normal)
  inv_mass_sum := body_a.inv_mass + body_b.inv_mass
  angular_factor_a := linalg.dot(body_a.inv_inertia * r_a_cross_n, r_a_cross_n)
  angular_factor_b := linalg.dot(body_b.inv_inertia * r_b_cross_n, r_b_cross_n)
  normal_mass := inv_mass_sum + angular_factor_a + angular_factor_b
  if normal_mass > math.F32_EPSILON {
    contact.normal_mass = 1.0 / normal_mass
  } else {
    contact.normal_mass = 0
  }
  contact.tangent1, contact.tangent2 = compute_tangent_basis(contact.normal)
  #unroll for i in 0 ..< 2 {
    tangent := i == 0 ? contact.tangent1 : contact.tangent2
    r_a_cross_t := vector_cross3(contact.r_a, tangent)
    r_b_cross_t := vector_cross3(contact.r_b, tangent)
    angular_factor_a_t := linalg.dot(body_a.inv_inertia * r_a_cross_t, r_a_cross_t)
    angular_factor_b_t := linalg.dot(body_b.inv_inertia * r_b_cross_t, r_b_cross_t)
    tangent_mass := inv_mass_sum + angular_factor_a_t + angular_factor_b_t
    if tangent_mass > math.F32_EPSILON {
      contact.tangent_mass[i] = 1.0 / tangent_mass
    } else {
      contact.tangent_mass[i] = 0
    }
  }
  penetration_to_resolve := max(contact.penetration - SLOP, 0.0)
  contact.bias = (BAUMGARTE_COEF / dt) * penetration_to_resolve
  vel_a := body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
  vel_b := body_b.velocity + vector_cross3(body_b.angular_velocity, contact.r_b)
  relative_velocity := vel_b - vel_a
  velocity_along_normal := linalg.dot(relative_velocity, contact.normal)
  if velocity_along_normal < RESTITUTION_THRESHOLD {
    contact.bias += -contact.restitution * velocity_along_normal
  }
}

prepare_contact_dynamic_static :: proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
  dt: f32,
) {
  contact.r_a = contact.point - body_a.position
  r_a_cross_n := vector_cross3(contact.r_a, contact.normal)
  inv_mass_sum := body_a.inv_mass
  angular_factor_a := linalg.dot(body_a.inv_inertia * r_a_cross_n, r_a_cross_n)
  normal_mass := inv_mass_sum + angular_factor_a
  if normal_mass > math.F32_EPSILON {
    contact.normal_mass = 1.0 / normal_mass
  } else {
    contact.normal_mass = 0
  }
  contact.tangent1, contact.tangent2 = compute_tangent_basis(contact.normal)
  #unroll for i in 0 ..< 2 {
    tangent := i == 0 ? contact.tangent1 : contact.tangent2
    r_a_cross_t := vector_cross3(contact.r_a, tangent)
    angular_factor_a_t := linalg.dot(body_a.inv_inertia * r_a_cross_t, r_a_cross_t)
    tangent_mass := inv_mass_sum + angular_factor_a_t
    if tangent_mass > math.F32_EPSILON {
      contact.tangent_mass[i] = 1.0 / tangent_mass
    } else {
      contact.tangent_mass[i] = 0
    }
  }
  penetration_to_resolve := max(contact.penetration - SLOP, 0.0)
  contact.bias = (BAUMGARTE_COEF / dt) * penetration_to_resolve
  vel_a := body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
  relative_velocity := -vel_a
  velocity_along_normal := linalg.dot(relative_velocity, contact.normal)
  if velocity_along_normal < RESTITUTION_THRESHOLD {
    contact.bias += -contact.restitution * velocity_along_normal
  }
}

prepare_contact :: proc {
  prepare_contact_dynamic_dynamic,
  prepare_contact_dynamic_static,
}

warmstart_contact_dynamic_dynamic :: proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
) {
  impulse_n := contact.normal * contact.normal_impulse
  apply_impulse_at_point(body_a, -impulse_n, contact.point)
  apply_impulse_at_point(body_b, impulse_n, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  #unroll for i in 0 ..< 2 {
    impulse_t := tangents[i] * contact.tangent_impulse[i]
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
    apply_impulse_at_point(body_b, impulse_t, contact.point)
  }
}

warmstart_contact_dynamic_static :: proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
) {
  impulse_n := contact.normal * contact.normal_impulse
  apply_impulse_at_point(body_a, -impulse_n, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  #unroll for i in 0 ..< 2 {
    impulse_t := tangents[i] * contact.tangent_impulse[i]
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
  }
}

warmstart_contact :: proc {
  warmstart_contact_dynamic_dynamic,
  warmstart_contact_dynamic_static,
}

resolve_contact_dynamic_dynamic :: proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
) {
  vel_a := body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
  vel_b := body_b.velocity + vector_cross3(body_b.angular_velocity, contact.r_b)
  relative_velocity := vel_b - vel_a
  velocity_along_normal := linalg.dot(relative_velocity, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal + contact.bias)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  delta_impulse = contact.normal_impulse - old_impulse
  impulse := contact.normal * delta_impulse
  apply_impulse_at_point(body_a, -impulse, contact.point)
  apply_impulse_at_point(body_b, impulse, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  max_friction := contact.friction * contact.normal_impulse
  #unroll for i in 0 ..< 2 {
    vel_a = body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
    vel_b = body_b.velocity + vector_cross3(body_b.angular_velocity, contact.r_b)
    velocity_along_tangent := linalg.dot(vel_b - vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
    apply_impulse_at_point(body_b, impulse_t, contact.point)
  }
}

resolve_contact_dynamic_static :: proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
) {
  vel_a := body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
  velocity_along_normal := linalg.dot(-vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal + contact.bias)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  delta_impulse = contact.normal_impulse - old_impulse
  impulse := contact.normal * delta_impulse
  apply_impulse_at_point(body_a, -impulse, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  max_friction := contact.friction * contact.normal_impulse
  #unroll for i in 0 ..< 2 {
    vel_a = body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
    velocity_along_tangent := linalg.dot(-vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
  }
}

resolve_contact :: proc {
  resolve_contact_dynamic_dynamic,
  resolve_contact_dynamic_static,
}

resolve_contact_no_bias_dynamic_dynamic :: proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
) {
  vel_a := body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
  vel_b := body_b.velocity + vector_cross3(body_b.angular_velocity, contact.r_b)
  velocity_along_normal := linalg.dot(vel_b - vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  impulse := contact.normal * (contact.normal_impulse - old_impulse)
  apply_impulse_at_point(body_a, -impulse, contact.point)
  apply_impulse_at_point(body_b, impulse, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  max_friction := contact.friction * contact.normal_impulse
  for i in 0 ..< 2 {
    vel_a = body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
    vel_b = body_b.velocity + vector_cross3(body_b.angular_velocity, contact.r_b)
    velocity_along_tangent := linalg.dot(vel_b - vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
    apply_impulse_at_point(body_b, impulse_t, contact.point)
  }
}

resolve_contact_no_bias_dynamic_static :: proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
) {
  vel_a := body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
  velocity_along_normal := linalg.dot(-vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  impulse := contact.normal * (contact.normal_impulse - old_impulse)
  apply_impulse_at_point(body_a, -impulse, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  max_friction := contact.friction * contact.normal_impulse
  for i in 0 ..< 2 {
    vel_a = body_a.velocity + vector_cross3(body_a.angular_velocity, contact.r_a)
    velocity_along_tangent := linalg.dot(-vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
  }
}

resolve_contact_no_bias :: proc {
  resolve_contact_no_bias_dynamic_dynamic,
  resolve_contact_no_bias_dynamic_static,
}

compute_tangent_basis :: proc(normal: [3]f32) -> ([3]f32, [3]f32) {
  tangent1 := linalg.orthogonal(normal)
  tangent2 := vector_cross3(normal, tangent1)
  return tangent1, tangent2
}
