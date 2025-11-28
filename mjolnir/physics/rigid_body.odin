package physics

import "../geometry"
import "../resources"
import "core:math/linalg"

RigidBody :: struct {
  node_handle:          resources.NodeHandle,
  collider_handle:      ColliderHandle,
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
  cached_aabb:          geometry.Aabb,
}

rigid_body_init :: proc(
  self: ^RigidBody,
  node_handle: resources.NodeHandle,
  mass: f32,
  is_static := false,
  enable_rotation := true,
  trigger_only := false,
) {
  self.node_handle = node_handle
  self.mass = mass
  self.inv_mass = is_static ? 0.0 : 1.0 / mass
  self.restitution = 0.2 // Low bounce - objects stay in contact
  self.friction = 0.8 // High friction - sliding slows down quickly
  self.linear_damping = 0.01 // 1% velocity loss per second
  self.angular_damping = 0.05 // 5% angular velocity loss per second
  self.is_static = is_static
  self.enable_rotation = enable_rotation // turn this to false to stop rotating body (for character simulation)
  self.trigger_only = trigger_only // turn this to true to stop response to collision resolution
  self.gravity_scale = 1.0
  self.drag_coefficient = 0.47 // sphere drag coefficient (0.47), cube ~1.05, use 0.1-2.0 range
  self.cross_sectional_area = 0.0 // 0 = auto-calculate from mass
  self.inertia = is_static ? {} : linalg.MATRIX3F32_IDENTITY
  self.inv_inertia = is_static ? {} : linalg.MATRIX3F32_IDENTITY
}

set_mass :: proc(self: ^RigidBody, mass: f32) {
  if self.is_static do return
  if mass <= 0.0 do return
  old_mass := self.mass
  self.mass = mass
  self.inv_mass = 1.0 / mass
  // Scale inertia tensor proportionally if it was set
  if old_mass > 0.0 {
    mass_ratio := mass / old_mass
    self.inertia = mass_ratio * self.inertia
    self.inv_inertia = linalg.matrix3_inverse(self.inertia)
  }
}

set_box_inertia :: proc(self: ^RigidBody, half_extents: [3]f32) {
  if self.is_static do return
  m := self.mass
  v := half_extents * half_extents
  self.inertia = linalg.matrix3_scale(
    [3]f32{v.y + v.z, v.x + v.z, v.x + v.y} * m / 3.0,
  )
  self.inv_inertia = linalg.matrix3_inverse(self.inertia)
}

set_sphere_inertia :: proc(self: ^RigidBody, radius: f32) {
  if self.is_static do return
  i := (2.0 / 5.0) * self.mass * radius * radius
  self.inertia = linalg.matrix3_scale([3]f32{i, i, i})
  self.inv_inertia = linalg.matrix3_inverse(self.inertia)
}

set_capsule_inertia :: proc(self: ^RigidBody, radius: f32, height: f32) {
  if self.is_static do return
  m := self.mass
  r2 := radius * radius
  h2 := height * height
  ix := (m / 12.0) * (3.0 * r2 + h2)
  iy := (m / 2.0) * r2
  self.inertia = linalg.matrix3_scale([3]f32{ix, iy, ix})
  self.inv_inertia = linalg.matrix3_inverse(self.inertia)
}

apply_force :: proc(self: ^RigidBody, force: [3]f32) {
  if self.is_static do return
  self.force += force
}

apply_force_at_point :: proc(
  self: ^RigidBody,
  force: [3]f32,
  point: [3]f32,
  center: [3]f32,
) {
  if self.is_static do return
  self.force += force
  if !self.enable_rotation do return
  r := point - center
  self.torque += linalg.cross(r, force)
}

apply_impulse :: proc(self: ^RigidBody, impulse: [3]f32) {
  if self.is_static do return
  self.velocity += impulse * self.inv_mass
}

apply_impulse_at_point :: proc(
  self: ^RigidBody,
  impulse: [3]f32,
  point: [3]f32,
  center: [3]f32,
) {
  if self.is_static do return
  self.velocity += impulse * self.inv_mass
  if !self.enable_rotation do return
  r := point - center
  angular_impulse := linalg.cross(r, impulse)
  self.angular_velocity += self.inv_inertia * angular_impulse
}

integrate :: proc(self: ^RigidBody, dt: f32) {
  if self.is_static || self.is_kinematic || self.trigger_only do return
  // Apply forces
  self.velocity += self.force * self.inv_mass * dt
  if self.enable_rotation {
    self.angular_velocity += (self.inv_inertia * self.torque) * dt
  }
  // Apply damping (exponential decay)
  damping_factor := 1.0 - self.linear_damping
  angular_damping_factor := 1.0 - self.angular_damping
  self.velocity *= damping_factor
  if self.enable_rotation {
    self.angular_velocity *= angular_damping_factor
  } else {
    self.angular_velocity = {}
  }
  clear_forces(self)
}

clear_forces :: proc(self: ^RigidBody) {
  self.force = {}
  self.torque = {}
}

update_cached_aabb :: proc(
  self: ^RigidBody,
  collider: ^Collider,
  position: [3]f32,
) {
  self.cached_aabb = collider_calculate_aabb(collider, position)
}
