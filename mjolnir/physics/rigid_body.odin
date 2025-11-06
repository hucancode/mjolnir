package physics

import "../resources"
import "core:math/linalg"

RigidBody :: struct {
  node_handle:          resources.Handle,
  collider_handle:      resources.Handle,
  mass:                 f32,
  inv_mass:             f32,
  inertia:              matrix[3, 3]f32,
  inv_inertia:          matrix[3, 3]f32,
  velocity:             [3]f32,
  angular_velocity:     [3]f32,
  force:                [3]f32,
  torque:               [3]f32,
  restitution:          f32,
  friction:             f32,
  linear_damping:       f32,
  angular_damping:      f32,
  is_static:            bool,
  is_kinematic:         bool,
  enable_rotation:      bool,
  trigger_only:         bool,
  gravity_scale:        f32,
  drag_coefficient:     f32,
  cross_sectional_area: f32, // m2 - set to 0 for automatic calculation
}

rigid_body_create :: proc(
  node_handle: resources.Handle,
  mass: f32,
  is_static := false,
  enable_rotation := true,
  trigger_only := false,
) -> RigidBody {
  return RigidBody {
    node_handle          = node_handle,
    mass                 = mass,
    inv_mass             = is_static ? 0.0 : 1.0 / mass,
    restitution          = 0.2, // Low bounce - objects stay in contact
    friction             = 0.8, // High friction - sliding slows down quickly
    linear_damping       = 0.01, // 1% velocity loss per second
    angular_damping      = 0.05, // 5% angular velocity loss per second
    is_static            = is_static,
    enable_rotation      = enable_rotation, // turn this to false to stop rotating body (for character simulation)
    trigger_only         = trigger_only, // turn this to true to stop response to collision resolution
    gravity_scale        = 1.0,
    drag_coefficient     = 0.47,  // sphere drag coefficient (0.47), cube ~1.05, use 0.1-2.0 range
    cross_sectional_area = 0.0,   // 0 = auto-calculate from mass
    inertia              = is_static ? {} : linalg.MATRIX3F32_IDENTITY,
    inv_inertia          = is_static ? {} : linalg.MATRIX3F32_IDENTITY,
  }
}

rigid_body_set_mass :: proc(body: ^RigidBody, mass: f32) {
  if body.is_static do return
  if mass <= 0.0 do return
  old_mass := body.mass
  body.mass = mass
  body.inv_mass = 1.0 / mass
  // Scale inertia tensor proportionally if it was set
  if old_mass > 0.0 {
    mass_ratio := mass / old_mass
    body.inertia = mass_ratio * body.inertia
    body.inv_inertia = linalg.matrix3_inverse_f32(body.inertia)
  }
}

rigid_body_set_box_inertia :: proc(body: ^RigidBody, half_extents: [3]f32) {
  if body.is_static do return
  m := body.mass
  x2 := half_extents.x * half_extents.x
  y2 := half_extents.y * half_extents.y
  z2 := half_extents.z * half_extents.z
  body.inertia = linalg.matrix3_scale_f32({y2 + z2, x2 + z2, x2 + y2} * m / 3.0)
  body.inv_inertia = linalg.matrix3_inverse_f32(body.inertia)
}

rigid_body_set_sphere_inertia :: proc(body: ^RigidBody, radius: f32) {
  if body.is_static do return
  i := (2.0 / 5.0) * body.mass * radius * radius
  body.inertia = linalg.matrix3_scale_f32({i, i, i})
  body.inv_inertia = linalg.matrix3_inverse_f32(body.inertia)
}

rigid_body_set_capsule_inertia :: proc(
  body: ^RigidBody,
  radius: f32,
  height: f32,
) {
  if body.is_static do return
  m := body.mass
  r2 := radius * radius
  h2 := height * height
  ix := (m / 12.0) * (3.0 * r2 + h2)
  iy := (m / 2.0) * r2
  body.inertia = linalg.matrix3_scale_f32({ix, iy, ix})
  body.inv_inertia = linalg.matrix3_inverse_f32(body.inertia)
}

rigid_body_apply_force :: proc(body: ^RigidBody, force: [3]f32) {
  if body.is_static do return
  body.force += force
}

rigid_body_apply_force_at_point :: proc(
  body: ^RigidBody,
  force: [3]f32,
  point: [3]f32,
  center: [3]f32,
) {
  if body.is_static do return
  body.force += force
  if !body.enable_rotation do return
  r := point - center
  body.torque += linalg.cross(r, force)
}

rigid_body_apply_impulse :: proc(body: ^RigidBody, impulse: [3]f32) {
  if body.is_static do return
  body.velocity += impulse * body.inv_mass
}

rigid_body_apply_impulse_at_point :: proc(
  body: ^RigidBody,
  impulse: [3]f32,
  point: [3]f32,
  center: [3]f32,
) {
  if body.is_static do return
  body.velocity += impulse * body.inv_mass
  if !body.enable_rotation do return
  r := point - center
  angular_impulse := linalg.cross(r, impulse)
  body.angular_velocity += body.inv_inertia * angular_impulse
}

rigid_body_integrate :: proc(body: ^RigidBody, dt: f32) {
  if body.is_static || body.is_kinematic || body.trigger_only do return
  // Apply forces
  body.velocity += body.force * body.inv_mass * dt
  if body.enable_rotation {
    body.angular_velocity += (body.inv_inertia * body.torque) * dt
  }
  // Apply damping (exponential decay)
  damping_factor := 1.0 - body.linear_damping
  angular_damping_factor := 1.0 - body.angular_damping
  body.velocity *= damping_factor
  if body.enable_rotation {
    body.angular_velocity *= angular_damping_factor
  } else {
    body.angular_velocity = {}
  }
  // Clear forces
  rigid_body_clear_forces(body)
}

rigid_body_clear_forces :: proc(body: ^RigidBody) {
  body.force = {}
  body.torque = {}
}
