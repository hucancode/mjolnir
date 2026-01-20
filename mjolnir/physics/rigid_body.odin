package physics

import "../geometry"
import "../resources"
import "core:math"
import "core:math/linalg"

RigidBody :: struct {
  position:             [3]f32,
  rotation:             quaternion128,
  collider_handle:      ColliderHandle,
  restitution:          f32,
  friction:             f32,
  trigger_only:         bool,
  cached_aabb:          geometry.Aabb,
  cached_sphere_center: [3]f32,
  cached_sphere_radius: f32,
}

StaticRigidBody :: struct {
  using base: RigidBody,
}

DynamicRigidBody :: struct {
  using base: RigidBody,
  mass:                 f32,
  inv_mass:             f32,
  inertia:              matrix[3, 3]f32,
  inv_inertia:          matrix[3, 3]f32,
  velocity:             [3]f32,
  angular_velocity:     [3]f32,
  force:                [3]f32,
  torque:               [3]f32,
  linear_damping:       f32,
  angular_damping:      f32,
  is_kinematic:         bool,
  enable_rotation:      bool,
  gravity_scale:        f32,
  drag_coefficient:     f32,
  is_sleeping:          bool,
  sleep_timer:          f32,
  is_killed:            bool, // Flag for deferred removal
}

static_rigid_body_init :: proc(
  self: ^StaticRigidBody,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  trigger_only := false,
) {
  self.position = position
  self.rotation = rotation
  self.restitution = 0.2
  self.friction = 0.8
  self.trigger_only = trigger_only
}

rigid_body_init :: proc(
  self: ^DynamicRigidBody,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  enable_rotation := true,
  trigger_only := false,
) {
  self.position = position
  self.rotation = rotation
  self.mass = mass
  self.inv_mass = 1.0 / mass
  self.restitution = 0.2
  self.friction = 0.8
  self.linear_damping = 0.01
  self.angular_damping = 0.05
  self.enable_rotation = enable_rotation
  self.trigger_only = trigger_only
  self.gravity_scale = 1.0
  self.drag_coefficient = 0.47
  self.inertia = linalg.MATRIX3F32_IDENTITY
  self.inv_inertia = linalg.MATRIX3F32_IDENTITY
  self.is_sleeping = false
  self.sleep_timer = 0.0
}

wake_up :: #force_inline proc(self: ^DynamicRigidBody) {
  self.is_sleeping = false
  self.sleep_timer = 0.0
}

set_mass :: proc(self: ^DynamicRigidBody, mass: f32) {
  if mass <= 0.0 do return
  old_mass := self.mass
  self.mass = mass
  self.inv_mass = 1.0 / mass
  if old_mass > 0.0 {
    mass_ratio := mass / old_mass
    self.inertia = mass_ratio * self.inertia
    self.inv_inertia = linalg.matrix3_inverse(self.inertia)
  }
}

set_box_inertia :: proc(self: ^DynamicRigidBody, half_extents: [3]f32) {
  m := self.mass
  v := half_extents * half_extents
  self.inertia = linalg.matrix3_scale(
    [3]f32{v.y + v.z, v.x + v.z, v.x + v.y} * m / 3.0,
  )
  self.inv_inertia = linalg.matrix3_inverse(self.inertia)
}

set_sphere_inertia :: proc(self: ^DynamicRigidBody, radius: f32) {
  i := (2.0 / 5.0) * self.mass * radius * radius
  self.inertia = linalg.matrix3_scale([3]f32{i, i, i})
  self.inv_inertia = linalg.matrix3_inverse(self.inertia)
}

set_cylinder_inertia :: proc(self: ^DynamicRigidBody, radius: f32, height: f32) {
  m := self.mass
  r2 := radius * radius
  h2 := height * height
  ix := (m / 12.0) * (3.0 * r2 + h2)
  iy := (m / 2.0) * r2
  self.inertia = linalg.matrix3_scale([3]f32{ix, iy, ix})
  self.inv_inertia = linalg.matrix3_inverse(self.inertia)
}

apply_force :: proc(self: ^DynamicRigidBody, force: [3]f32) {
  self.force += force
  wake_up(self)
}

apply_force_at_point :: proc(
  self: ^DynamicRigidBody,
  force: [3]f32,
  point: [3]f32,
  center: [3]f32,
) {
  self.force += force
  if !self.enable_rotation do return
  r := point - center
  self.torque += linalg.cross(r, force)
  wake_up(self)
}

apply_impulse :: proc(self: ^DynamicRigidBody, impulse: [3]f32) {
  self.velocity += impulse * self.inv_mass
  wake_up(self)
}

apply_impulse_at_point :: proc(
  self: ^DynamicRigidBody,
  impulse: [3]f32,
  point: [3]f32,
) {
  self.velocity += impulse * self.inv_mass
  if !self.enable_rotation do return
  r := point - self.position
  angular_impulse := linalg.cross(r, impulse)
  self.angular_velocity += self.inv_inertia * angular_impulse
  wake_up(self)
}

integrate :: proc(self: ^DynamicRigidBody, dt: f32) {
  if self.is_kinematic || self.trigger_only || self.is_sleeping do return
  self.velocity += self.force * self.inv_mass * dt
  if self.enable_rotation {
    self.angular_velocity += (self.inv_inertia * self.torque) * dt
  }
  damping_factor := math.pow(1.0 - self.linear_damping, dt)
  angular_damping_factor := math.pow(1.0 - self.angular_damping, dt)
  self.velocity *= damping_factor
  if self.enable_rotation {
    self.angular_velocity *= angular_damping_factor
  } else {
    self.angular_velocity = {}
  }
  clear_forces(self)
}

clear_forces :: proc(self: ^DynamicRigidBody) {
  self.force = {}
  self.torque = {}
}

update_cached_aabb_static :: proc(self: ^StaticRigidBody, collider: ^Collider) {
  self.cached_aabb = collider_calculate_aabb(
    collider,
    self.position,
    self.rotation,
  )
  self.cached_sphere_center = geometry.aabb_center(self.cached_aabb)
  aabb_half_extents := (self.cached_aabb.max - self.cached_aabb.min) * 0.5
  self.cached_sphere_radius = linalg.length(aabb_half_extents)
}

update_cached_aabb_dynamic :: proc(self: ^DynamicRigidBody, collider: ^Collider) {
  self.cached_aabb = collider_calculate_aabb(
    collider,
    self.position,
    self.rotation,
  )
  self.cached_sphere_center = geometry.aabb_center(self.cached_aabb)
  aabb_half_extents := (self.cached_aabb.max - self.cached_aabb.min) * 0.5
  self.cached_sphere_radius = linalg.length(aabb_half_extents)
}

update_cached_aabb :: proc {
  update_cached_aabb_static,
  update_cached_aabb_dynamic,
}
