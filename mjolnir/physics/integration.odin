package physics

import "core:math"
import "core:math/linalg"

integrate_positions :: proc(world: ^World, dt: f32, ccd_handled: []bool) {
  pool := &world.bodies
  for i in 0 ..< len(pool.entries) {
    if !pool.entries[i].active do continue
    body := &pool.entries[i].item
    if body.is_killed || body.is_sleeping do continue
    if i < len(ccd_handled) && ccd_handled[i] {
      // CCD already advanced position to TOI; pseudo state should not leak into the next substep.
      body.pseudo_velocity = {}
      body.pseudo_angular_velocity = {}
      continue
    }
    // Pseudo velocity is a position-only correction (split impulse). Apply once, discard.
    body.position += (body.velocity + body.pseudo_velocity) * dt
    if body.enable_rotation {
      w := body.angular_velocity + body.pseudo_angular_velocity
      if w.x * w.x + w.y * w.y + w.z * w.z >= math.F32_EPSILON {
        q := body.rotation
        omega_q := quaternion(w = 0, x = w.x, y = w.y, z = w.z)
        dq := omega_q * q
        body.rotation = linalg.normalize(quaternion(
          w = q.w + 0.5 * dq.w * dt,
          x = q.x + 0.5 * dq.x * dt,
          y = q.y + 0.5 * dq.y * dt,
          z = q.z + 0.5 * dq.z * dt,
        ))
      }
    }
    body.pseudo_velocity = {}
    body.pseudo_angular_velocity = {}
    update_cached_aabb(&body.base)
  }
}
