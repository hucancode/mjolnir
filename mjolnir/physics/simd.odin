package physics

import cont "../containers"
import "../geometry"
import "core:math"
import "core:math/linalg"

// Re-export SIMD types from geometry package for convenience
SIMD_Mode :: geometry.SIMD_Mode
f32x4 :: geometry.f32x4
f32x8 :: geometry.f32x8

// Note: simd_mode, simd_lanes, and SIMD constants are in geometry package
// Use geometry.simd_mode, geometry.SIMD_ONE_4, etc. directly

// Re-export geometry SIMD batch functions
aabb_intersects_batch4 :: geometry.aabb_intersects_batch4
obb_to_aabb_batch4 :: geometry.obb_to_aabb_batch4
vector_cross3_batch4 :: geometry.vector_cross3_batch4
quaternion_mul_vector3_batch4 :: geometry.quaternion_mul_vector3_batch4
vector_dot3_batch4 :: geometry.vector_dot3_batch4
vector_length3_batch4 :: geometry.vector_length3_batch4
vector_normalize3_batch4 :: geometry.vector_normalize3_batch4

// Configurable SIMD width - can be overridden at compile time
WIDTH :: #config(PHYSICS_SIMD_WIDTH, 8)  // Default to 8-wide (AVX2)

// SIMD constants for configured width
when WIDTH == 4 {
  SIMD_ZERO :: f32x4{0, 0, 0, 0}
  SIMD_ONE :: f32x4{1, 1, 1, 1}
} else when WIDTH == 8 {
  SIMD_ZERO :: f32x8{0, 0, 0, 0, 0, 0, 0, 0}
  SIMD_ONE :: f32x8{1, 1, 1, 1, 1, 1, 1, 1}
}

// Physics-specific SIMD integration functions

apply_gravity :: proc(world: ^World) {
  pool := &world.bodies
  for i in 0..<len(pool.entries) {
    if !pool.entries[i].active do continue
    body := &pool.entries[i].item
    if body.is_killed || body.is_sleeping do continue

    gravity_force := world.gravity * body.mass
    body.force += gravity_force
  }
}

integrate_velocities :: proc(world: ^World, dt: f32) {
  pool := &world.bodies
  for i in 0..<len(pool.entries) {
    if !pool.entries[i].active do continue
    body := &pool.entries[i].item
    if body.is_killed || body.is_sleeping do continue

    body.velocity += body.force * body.inv_mass * dt
    damping_factor := math.pow(1.0 - body.linear_damping, dt)
    body.velocity *= damping_factor
    body.force = {}
    body.torque = {}
  }
}

integrate_positions :: proc(world: ^World, dt: f32, ccd_handled: []bool) {
  pool := &world.bodies
  for i in 0..<len(pool.entries) {
    if !pool.entries[i].active do continue
    body := &pool.entries[i].item
    if body.is_killed || body.is_sleeping do continue
    if i < len(ccd_handled) && ccd_handled[i] do continue

    body.position += body.velocity * dt
  }
  integrate_rotations(world, dt, ccd_handled)
}

integrate_rotations :: proc(world: ^World, dt: f32, ccd_handled: []bool) {
  pool := &world.bodies
  for i in 0..<len(pool.entries) {
    if !pool.entries[i].active do continue
    body := &pool.entries[i].item
    if body.is_killed || body.is_sleeping do continue
    if i < len(ccd_handled) && ccd_handled[i] do continue
    if !body.enable_rotation do continue

    ang_vel_mag_sq := linalg.length2(body.angular_velocity)
    if ang_vel_mag_sq >= math.F32_EPSILON {
      omega_quat := quaternion(
        w = 0,
        x = body.angular_velocity.x,
        y = body.angular_velocity.y,
        z = body.angular_velocity.z,
      )
      q_old := body.rotation
      q_dot := omega_quat * q_old
      q_dot.w *= 0.5
      q_dot.x *= 0.5
      q_dot.y *= 0.5
      q_dot.z *= 0.5
      q_new := quaternion(
        w = q_old.w + q_dot.w * dt,
        x = q_old.x + q_dot.x * dt,
        y = q_old.y + q_dot.y * dt,
        z = q_old.z + q_dot.z * dt,
      )
      q_new = linalg.normalize(q_new)
      body.rotation = q_new
    }
  }
}
