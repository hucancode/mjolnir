package physics

import cont "../containers"
import "../geometry"
import "core:math/linalg"

// Body is a rigid body. Mass decides the role: mass > 0 is dynamic (fully simulated);
// mass 0 is infinite mass. An infinite-mass body is static until it is
// first moved with set_pose/set_velocity; from then on it is kinematic —
// moved by its velocity, pushing dynamic bodies, never pushed back.
// A sensor reports overlaps in `World.sensor_overlaps` and is never
// simulated, solved or hit by queries; move it with `set_pose`.
Body :: struct {
  user:                 cont.Handle, // caller-owned link back, e.g. the scene node this body drives
  is_sensor:            bool,
  moving:               bool, // read-only: integrated and kept in the dynamic BVH
  enable_rotation:      bool,
  is_sleeping:          bool,
  position:             [3]f32,
  rotation:             quaternion128,
  collider:             Collider,
  restitution:          f32,
  friction:             f32,
  velocity:             [3]f32,
  angular_velocity:     [3]f32,
  linear_damping:       f32,
  angular_damping:      f32,
  using _: Body_State,
}

@(private)
Body_State :: struct {
  cached_aabb:          geometry.Aabb,
  cached_sphere_center: [3]f32,
  cached_sphere_radius: f32,
  inv_mass:             f32,
  inv_inertia:          [3]f32, // Diagonal inverse inertia in body space
  inv_inertia_world:    matrix[3, 3]f32,
  force:                [3]f32,
  torque:               [3]f32,
  sleep_timer:          f32,
  // Position at frame start (after CCD, before substeps) — the solver
  // recovers per-substep contact separation from position - position0.
  position0:            [3]f32,
}

@(private)
is_dynamic :: #force_inline proc "contextless" (self: ^Body) -> bool {
  return self.inv_mass > 0
}

@(private)
body_init :: proc(
  self: ^Body,
  position: [3]f32,
  rotation: quaternion128,
  collider: Collider,
  mass: f32,
  is_sensor: bool,
  user: cont.Handle,
) {
  self^ = {
    user            = user,
    is_sensor       = is_sensor,
    enable_rotation = true,
    position        = position,
    rotation        = rotation,
    collider        = collider,
    restitution     = 0.2,
    friction        = 0.8,
    linear_damping  = 0.01,
    angular_damping = 0.05,
  }
  if mass > 0 && !is_sensor {
    self.inv_mass = 1.0 / mass
    self.moving = true
  }
  update_inertia(self)
  update_cached_aabb(self)
}

// Solid-body inertia for the collider shape at the current mass.
@(private)
update_inertia :: proc(self: ^Body) {
  self.inv_inertia = collider_inv_inertia(&self.collider, self.inv_mass)
  update_world_inertia(self)
}

// Implicit gyroscopic torque: one Newton-Raphson iteration on
// I*(w2−w1) + h*(w2 * I*w2) = 0 in body frame. Slightly
// dissipative but unconditionally stable — energy can only decrease.
@(private)
solve_gyroscopic :: proc(body: ^Body, dt: f32) {
  ii := body.inv_inertia
  if ii.x <= 0 || ii.y <= 0 || ii.z <= 0 do return
  q := body.rotation
  w1 := linalg.quaternion128_mul_vector3(
    linalg.quaternion_inverse(q),
    body.angular_velocity,
  )
  inertia := 1.0 / ii
  iw := inertia * w1
  f := dt * linalg.cross(w1, iw)
  i_mat := matrix[3, 3]f32{
    inertia.x, 0, 0,
    0, inertia.y, 0,
    0, 0, inertia.z,
  }
  jac := i_mat + dt * (geometry.skew(w1) * i_mat - geometry.skew(iw))
  w2 := w1 - linalg.inverse(jac) * f
  body.angular_velocity = linalg.quaternion128_mul_vector3(q, w2)
}

@(private)
update_world_inertia :: proc(self: ^Body) {
  if !self.enable_rotation {
    self.inv_inertia_world = {}
    return
  }
  r := linalg.matrix3_from_quaternion(self.rotation)
  d := matrix[3, 3]f32{
    self.inv_inertia.x, 0, 0,
    0, self.inv_inertia.y, 0,
    0, 0, self.inv_inertia.z,
  }
  self.inv_inertia_world = r * d * linalg.transpose(r)
}

@(private)
wake_up :: #force_inline proc(self: ^Body) {
  self.is_sleeping = false
  self.sleep_timer = 0.0
}

// Solver-internal impulse application; does not wake the body. Infinite-mass
// bodies are skipped so parallel solver threads never write them.
@(private)
apply_impulse_at_point :: #force_inline proc(
  self: ^Body,
  impulse: [3]f32,
  point: [3]f32,
) {
  if self.inv_mass == 0 do return
  self.velocity += impulse * self.inv_mass
  if !self.enable_rotation do return
  r := point - self.position
  self.angular_velocity += self.inv_inertia_world * linalg.cross(r, impulse)
}

@(private)
apply_angular_impulse :: #force_inline proc(self: ^Body, impulse: [3]f32) {
  if self.inv_mass == 0 || !self.enable_rotation do return
  self.angular_velocity += self.inv_inertia_world * impulse
}

@(private)
update_cached_aabb :: proc(self: ^Body) {
  self.cached_aabb = collider_calculate_aabb(
    &self.collider,
    self.position,
    self.rotation,
  )
  self.cached_sphere_center = geometry.aabb_center(self.cached_aabb)
  self.cached_sphere_radius = collider_bounding_radius(&self.collider)
}
