package physics

import "core:math"
import "core:math/linalg"

// Per-substep velocity integration: gravity, external force/torque, damping.
// Forces are held for the whole frame (cleared in step cleanup) so each
// substep integrates them with the substep dt — the TGS scheme.
// start/end index into world.awake_list (dense, prefiltered)
integrate_velocities_range :: proc(world: ^World, start, end: int, h: f32) {
  pool := &world.bodies
  list := world.awake_list[:]
  #no_bounds_check for li in start ..< end {
    body := &pool.entries[list[li]].item
    body.velocity += (world.gravity + body.force * body.inv_mass) * h
    body.velocity *= math.pow(1.0 - body.linear_damping, h)
    if body.enable_rotation {
      body.angular_velocity += (body.inv_inertia_world * body.torque) * h
      body.angular_velocity *= math.pow(1.0 - body.angular_damping, h)
    } else {
      body.angular_velocity = {}
    }
  }
}

// Per-substep position integration. AABBs are refreshed once per frame in
// finalize, not here — collision runs once per frame.
integrate_positions_range :: proc(world: ^World, start, end: int, h: f32, ccd_handled: []bool) {
  pool := &world.bodies
  list := world.awake_list[:]
  #no_bounds_check for li in start ..< end {
    i := int(list[li])
    body := &pool.entries[i].item
    if i < len(ccd_handled) && ccd_handled[i] do continue // CCD already advanced this body
    // Safety clamps: runaway state breaks CCD sweeps and quaternion integration
    speed_sq := linalg.length2(body.velocity)
    if speed_sq > MAX_LINEAR_SPEED * MAX_LINEAR_SPEED {
      body.velocity *= f32(MAX_LINEAR_SPEED) / math.sqrt(speed_sq)
    }
    max_omega := MAX_ROTATION_PER_STEP / h
    omega_sq := linalg.length2(body.angular_velocity)
    if omega_sq > max_omega * max_omega {
      body.angular_velocity *= max_omega / math.sqrt(omega_sq)
    }
    body.position += body.velocity * h
    if body.enable_rotation {
      solve_gyroscopic(body, h)
      w := body.angular_velocity
      if w.x * w.x + w.y * w.y + w.z * w.z >= math.F32_EPSILON {
        q := body.rotation
        omega_q := quaternion(w = 0, x = w.x, y = w.y, z = w.z)
        dq := omega_q * q
        body.rotation = linalg.normalize(quaternion(
          w = q.w + 0.5 * dq.w * h,
          x = q.x + 0.5 * dq.x * h,
          y = q.y + 0.5 * dq.y * h,
          z = q.z + 0.5 * dq.z * h,
        ))
        update_world_inertia(body)
      }
    }
  }
}
