package physics

import "../geometry"
import "../resources"
import "../world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

KILL_Y :: -50.0

PhysicsWorld :: struct {
  bodies:        resources.Pool(RigidBody),
  colliders:     resources.Pool(Collider),
  contacts:      [dynamic]Contact,
  gravity:       [3]f32,
  iterations:    i32,
  spatial_index: geometry.BVH(resources.Handle),
}

BroadPhaseEntry :: struct {
  handle: resources.Handle,
  bounds: geometry.Aabb,
}

init :: proc(
  world: ^PhysicsWorld,
  gravity := [3]f32{0, -9.81, 0},
) {
  resources.pool_init(&world.bodies)
  resources.pool_init(&world.colliders)
  world.contacts = make([dynamic]Contact)
  world.gravity = gravity
  world.iterations = 8
  world.spatial_index = geometry.BVH(resources.Handle) {
    nodes = make([dynamic]geometry.BVHNode),
    primitives = make([dynamic]resources.Handle),
    bounds_func = proc(h: resources.Handle) -> geometry.Aabb {
      return {}
    },
  }
}

destroy :: proc(world: ^PhysicsWorld) {
  resources.pool_destroy(world.bodies, proc(body: ^RigidBody) {})
  resources.pool_destroy(world.colliders, proc(col: ^Collider) {})
  delete(world.contacts)
  geometry.bvh_destroy(&world.spatial_index)
}

create_body :: proc(
  world: ^PhysicsWorld,
  node_handle: resources.Handle,
  mass: f32,
  is_static := false,
) -> (
  resources.Handle,
  ^RigidBody,
  bool,
) {
  handle, body, ok := resources.alloc(&world.bodies)
  if !ok {
    return {}, nil, false
  }
  body^ = rigid_body_create(node_handle, mass, is_static)
  return handle, body, true
}

destroy_body :: proc(
  world: ^PhysicsWorld,
  handle: resources.Handle,
) {
  body, _ := resources.get(world.bodies, handle)
  if body != nil && body.collider_handle.generation != 0 {
    resources.free(&world.colliders, body.collider_handle)
  }
  resources.free(&world.bodies, handle)
}

add_collider :: proc(
  world: ^PhysicsWorld,
  body_handle: resources.Handle,
  collider: Collider,
) -> (
  resources.Handle,
  ^Collider,
  bool,
) {
  body, body_ok := resources.get(world.bodies, body_handle)
  if !body_ok {
    return {}, nil, false
  }
  handle, col_ptr, ok := resources.alloc(&world.colliders)
  if !ok {
    return {}, nil, false
  }
  col_ptr^ = collider
  body.collider_handle = handle
  return handle, col_ptr, true
}

step :: proc(physics: ^PhysicsWorld, w: ^world.World, dt: f32) {
  clear(&physics.contacts)
  for &entry in physics.bodies.entries {
    if !entry.active {
      continue
    }
    body := &entry.item
    if !body.is_static && !body.is_kinematic {
      gravity_force := physics.gravity * body.mass * body.gravity_scale
      rigid_body_apply_force(body, gravity_force)
    }
  }
  for &entry in physics.bodies.entries {
    if !entry.active {
      continue
    }
    body := &entry.item
    rigid_body_integrate(body, dt)
  }
  // Track which bodies were handled by CCD
  ccd_handled := make(
    [dynamic]bool,
    len(physics.bodies.entries),
    context.temp_allocator,
  )
  // Perform CCD for fast-moving objects
  ccd_threshold :: 2.0 // Objects moving faster than this use CCD
  for &entry_a, idx_a in physics.bodies.entries {
    if !entry_a.active {
      continue
    }
    body_a := &entry_a.item
    if body_a.is_static || body_a.collider_handle.generation == 0 {
      continue
    }
    // Check if moving fast enough for CCD
    velocity_mag := linalg.length(body_a.velocity)
    if velocity_mag < ccd_threshold {
      continue
    }
    node_a, node_a_ok := resources.get(w.nodes, body_a.node_handle)
    if !node_a_ok {
      continue
    }
    collider_a, col_a_ok := resources.get(
      physics.colliders,
      body_a.collider_handle,
    )
    if !col_a_ok {
      continue
    }
    pos_a := node_a.transform.position
    motion := body_a.velocity * dt
    earliest_toi := f32(1.0)
    earliest_normal := [3]f32{0, 1, 0}
    earliest_body_b: ^RigidBody = nil
    has_ccd_hit := false
    // Check against all other colliders
    for &entry_b, idx_b in physics.bodies.entries {
      if !entry_b.active || idx_a == idx_b {
        continue
      }
      body_b := &entry_b.item
      if body_b.collider_handle.generation == 0 {
        continue
      }
      node_b, node_b_ok := resources.get(w.nodes, body_b.node_handle)
      if !node_b_ok {
        continue
      }
      collider_b, col_b_ok := resources.get(
        physics.colliders,
        body_b.collider_handle,
      )
      if !col_b_ok {
        continue
      }
      pos_b := node_b.transform.position
      toi := swept_test(collider_a, pos_a, motion, collider_b, pos_b)
      if toi.has_impact && toi.time < earliest_toi {
        earliest_toi = toi.time
        earliest_normal = toi.normal
        earliest_body_b = body_b
        has_ccd_hit = true
      }
    }
    // If we found a TOI, move to impact and reflect velocity
    if has_ccd_hit && earliest_toi < 0.99 {
      // Move to just before impact position
      safe_time := earliest_toi * 0.98
      node_a.transform.position += body_a.velocity * dt * safe_time
      // Reflect velocity along collision normal
      vel_along_normal := linalg.vector_dot(body_a.velocity, earliest_normal)
      if vel_along_normal < 0 {
        // Calculate restitution
        restitution := body_a.restitution
        if earliest_body_b != nil {
          restitution =
            (body_a.restitution + earliest_body_b.restitution) * 0.5
        }
        // Reflect normal component with restitution
        body_a.velocity -=
          earliest_normal * vel_along_normal * (1.0 + restitution)
        // Apply friction to tangent velocity
        friction := body_a.friction
        if earliest_body_b != nil {
          friction = (body_a.friction + earliest_body_b.friction) * 0.5
        }
        tangent_vel :=
          body_a.velocity -
          earliest_normal * linalg.vector_dot(body_a.velocity, earliest_normal)
        body_a.velocity -= tangent_vel * friction * 0.5
      }
      // Mark as handled by CCD - skip normal position integration
      ccd_handled[idx_a] = true
    }
  }
  broad_phase_entries := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  for &entry, idx in physics.bodies.entries {
    if !entry.active {
      continue
    }
    body := &entry.item
    if body.collider_handle.generation == 0 {
      continue
    }
    node, node_ok := resources.get(w.nodes, body.node_handle)
    if !node_ok {
      continue
    }
    collider, col_ok := resources.get(physics.colliders, body.collider_handle)
    if !col_ok {
      continue
    }
    pos := node.transform.position
    bounds := collider_get_aabb(collider, pos)
    handle := resources.Handle {
      index      = u32(idx),
      generation = entry.generation,
    }
    append(
      &broad_phase_entries,
      BroadPhaseEntry{handle = handle, bounds = bounds},
    )
  }
  for i in 0 ..< len(broad_phase_entries) {
    for j in i + 1 ..< len(broad_phase_entries) {
      entry_a := broad_phase_entries[i]
      entry_b := broad_phase_entries[j]
      if !geometry.aabb_intersects(entry_a.bounds, entry_b.bounds) {
        continue
      }
      body_a, body_a_ok := resources.get(physics.bodies, entry_a.handle)
      body_b, body_b_ok := resources.get(physics.bodies, entry_b.handle)
      if !body_a_ok || !body_b_ok {
        continue
      }
      if body_a.is_static && body_b.is_static {
        continue
      }
      if body_a.collider_handle.generation == 0 ||
         body_b.collider_handle.generation == 0 {
        continue
      }
      node_a, node_a_ok := resources.get(w.nodes, body_a.node_handle)
      node_b, node_b_ok := resources.get(w.nodes, body_b.node_handle)
      if !node_a_ok || !node_b_ok {
        continue
      }
      collider_a, col_a_ok := resources.get(
        physics.colliders,
        body_a.collider_handle,
      )
      collider_b, col_b_ok := resources.get(
        physics.colliders,
        body_b.collider_handle,
      )
      if !col_a_ok || !col_b_ok {
        continue
      }
      pos_a := node_a.transform.position
      pos_b := node_b.transform.position
      hit, point, normal, penetration := test_collision(
        collider_a,
        pos_a,
        collider_b,
        pos_b,
      )
      if hit {
        contact := Contact {
          body_a      = entry_a.handle,
          body_b      = entry_b.handle,
          point       = point,
          normal      = normal,
          penetration = penetration,
          restitution = (body_a.restitution + body_b.restitution) * 0.5,
          friction    = (body_a.friction + body_b.friction) * 0.5,
        }
        append(&physics.contacts, contact)
      }
    }
  }
  for _ in 0 ..< physics.iterations {
    for &contact in physics.contacts {
      body_a, body_a_ok := resources.get(physics.bodies, contact.body_a)
      body_b, body_b_ok := resources.get(physics.bodies, contact.body_b)
      if !body_a_ok || !body_b_ok {
        continue
      }
      node_a, node_a_ok := resources.get(w.nodes, body_a.node_handle)
      node_b, node_b_ok := resources.get(w.nodes, body_b.node_handle)
      if !node_a_ok || !node_b_ok {
        continue
      }
      pos_a := node_a.transform.position
      pos_b := node_b.transform.position
      resolve_contact(&contact, body_a, body_b, pos_a, pos_b)
      // Apply direct position correction
      resolve_contact_position(
        &contact,
        body_a,
        body_b,
        &node_a.transform.position,
        &node_b.transform.position,
      )
    }
  }
  for &entry, idx in physics.bodies.entries {
    if !entry.active {
      continue
    }
    body := &entry.item
    if body.is_static || body.is_kinematic {
      continue
    }
    // Skip if already handled by CCD
    if idx < len(ccd_handled) && ccd_handled[idx] {
      continue
    }
    node, node_ok := resources.get(w.nodes, body.node_handle)
    if !node_ok {
      continue
    }
    // Update position
    vel := body.velocity * dt
    geometry.transform_translate_by(&node.transform, vel.x, vel.y, vel.z)
    // Update rotation from angular velocity
    // Use quaternion integration: q_new = q_old + 0.5 * dt * (omega * q_old)
    // Skip rotation if angular velocity is negligible
    ang_vel_mag_sq := linalg.vector_dot(
      body.angular_velocity,
      body.angular_velocity,
    )
    if ang_vel_mag_sq > 0.0001 {
      // Create pure quaternion from angular velocity (w=0, xyz=angular_velocity)
      omega_quat := quaternion(
        w = 0,
        x = body.angular_velocity.x,
        y = body.angular_velocity.y,
        z = body.angular_velocity.z,
      )
      q_old := node.transform.rotation
      // Calculate derivative: q_dot = 0.5 * omega * q_old
      q_dot := omega_quat * q_old
      q_dot.w *= 0.5
      q_dot.x *= 0.5
      q_dot.y *= 0.5
      q_dot.z *= 0.5
      // Integrate: q_new = q_old + q_dot * dt
      q_new := quaternion(
        w = q_old.w + q_dot.w * dt,
        x = q_old.x + q_dot.x * dt,
        y = q_old.y + q_dot.y * dt,
        z = q_old.z + q_dot.z * dt,
      )
      // Normalize to prevent drift
      mag := math.sqrt(
        q_new.w * q_new.w +
        q_new.x * q_new.x +
        q_new.y * q_new.y +
        q_new.z * q_new.z,
      )
      if mag > 0.0001 {
        q_new.w /= mag
        q_new.x /= mag
        q_new.y /= mag
        q_new.z /= mag
        geometry.transform_rotate(&node.transform, q_new)
      }
    }
  }
  // Kill bodies that fall below kill_y threshold
  bodies_to_kill := make([dynamic]resources.Handle, context.temp_allocator)
  for &entry, idx in physics.bodies.entries {
    if !entry.active {
      continue
    }
    body := &entry.item
    if body.is_static || body.is_kinematic {
      continue
    }
    node, node_ok := resources.get(w.nodes, body.node_handle)
    if !node_ok {
      continue
    }
    if node.transform.position.y < KILL_Y {
      handle := resources.Handle {
        index      = u32(idx),
        generation = entry.generation,
      }
      append(&bodies_to_kill, handle)
    }
  }
  // Remove killed bodies
  for handle in bodies_to_kill {
    body, body_ok := resources.get(physics.bodies, handle)
    if body_ok {
      node, _ := resources.get(w.nodes, body.node_handle)
      log.infof(
        "Removing body at y=%.2f (below KILL_Y=%.2f)",
        node.transform.position.y,
        KILL_Y,
      )
    }
    destroy_body(physics, handle)
  }
}
