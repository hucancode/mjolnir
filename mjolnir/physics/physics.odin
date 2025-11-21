package physics

import cont "../containers"
import "../geometry"
import "../resources"
import "../world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

KILL_Y :: -50.0

PhysicsWorld :: struct {
  bodies:                resources.Pool(RigidBody),
  colliders:             resources.Pool(Collider),
  contacts:              [dynamic]Contact,
  prev_contacts:         map[u64]Contact, // Contact cache for warmstarting
  gravity:               [3]f32,
  iterations:            i32, // Per-substep iterations
  spatial_index:         geometry.BVH(BroadPhaseEntry),
  body_bounds:           [dynamic]geometry.Aabb,
  enable_air_resistance: bool,
  air_density:           f32, // kg/m3
}

BroadPhaseEntry :: struct {
  handle: resources.Handle,
  bounds: geometry.Aabb,
}

init :: proc(world: ^PhysicsWorld, gravity := [3]f32{0, -9.81, 0}) {
  cont.init(&world.bodies)
  cont.init(&world.colliders)
  world.contacts = make([dynamic]Contact)
  world.prev_contacts = make(map[u64]Contact)
  world.gravity = gravity
  world.iterations = 6
  world.spatial_index = geometry.BVH(BroadPhaseEntry) {
    nodes = make([dynamic]geometry.BVHNode),
    primitives = make([dynamic]BroadPhaseEntry),
    bounds_func = proc(entry: BroadPhaseEntry) -> geometry.Aabb {
      return entry.bounds
    },
  }
  world.body_bounds = make([dynamic]geometry.Aabb)
  world.enable_air_resistance = false
  world.air_density = 1.225 // Earth sea level air density
}

destroy :: proc(world: ^PhysicsWorld) {
  cont.destroy(world.bodies, proc(body: ^RigidBody) {})
  cont.destroy(world.colliders, proc(col: ^Collider) {})
  delete(world.body_bounds)
  delete(world.contacts)
  delete(world.prev_contacts)
  geometry.bvh_destroy(&world.spatial_index)
}

create_body :: proc(
  world: ^PhysicsWorld,
  node_handle: resources.Handle,
  mass: f32 = 1.0,
  is_static := false,
) -> (
  handle: resources.Handle,
  body: ^RigidBody,
  ok: bool,
) {
  handle, body = cont.alloc(&world.bodies) or_return
  body^ = rigid_body_create(node_handle, mass, is_static)
  ok = true
  return
}

destroy_body :: proc(world: ^PhysicsWorld, handle: resources.Handle) {
  body, ok := cont.get(world.bodies, handle)
  if ok {
    cont.free(&world.colliders, body.collider_handle)
  }
  cont.free(&world.bodies, handle)
}

add_collider :: proc(
  world: ^PhysicsWorld,
  body_handle: resources.Handle,
  collider: Collider,
) -> (
  handle: resources.Handle,
  col_ptr: ^Collider,
  ok: bool,
) {
  body := cont.get(world.bodies, body_handle) or_return
  handle, col_ptr = cont.alloc(&world.colliders) or_return
  col_ptr^ = collider
  body.collider_handle = handle
  return handle, col_ptr, true
}

step :: proc(physics: ^PhysicsWorld, w: ^world.World, dt: f32) {
  step_start := time.now()
  // Save previous contacts for warmstarting
  clear(&physics.prev_contacts)
  for contact in physics.contacts {
    hash := collision_pair_hash({contact.body_a, contact.body_b})
    physics.prev_contacts[hash] = contact
  }
  // Apply forces to all bodies (gravity, air resistance, etc.)
  for &entry in physics.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_static || body.is_kinematic || body.trigger_only {
      continue
    }
    // Apply gravity
    gravity_force := physics.gravity * body.mass * body.gravity_scale
    rigid_body_apply_force(body, gravity_force)
    if !physics.enable_air_resistance do continue
    // Apply air resistance (drag)
    // Drag force: F_d = -0.5 * p * v * v * C_d * A
    // Where: p=air density, v=velocity, C_d=drag coefficient, A=cross-sectional area
    vel_mag := linalg.length(body.velocity)
    if vel_mag < 0.001 do continue
    // Calculate cross-sectional area
    cross_section := body.cross_sectional_area
    calculate_cross_section: if cross_section <= 0.0 {
      // Auto-calculate from collider if available
      if body.collider_handle.generation == 0 {
        // No collider: fallback to mass-based estimate
        cross_section = math.pow(body.mass, 2.0 / 3.0) * 0.1
        break calculate_cross_section
      }
      collider := cont.get(physics.colliders, body.collider_handle) or_break calculate_cross_section
      // Estimate frontal area based on collider type
      switch c in collider.shape {
      case SphereCollider:
        cross_section = math.PI * c.radius * c.radius
      case CapsuleCollider:
        cross_section = math.PI * c.radius * c.radius
      case BoxCollider:
        // Frontal area of box (average of three face areas)
        cross_section = (c.half_extents.x * c.half_extents.y * 4.0 + c.half_extents.y * c.half_extents.z * 4.0 + c.half_extents.x * c.half_extents.z * 4.0) / 3.0
      case CylinderCollider:
        // Cross-section of cylinder (average of circular and rectangular face)
        cross_section = (math.PI * c.radius * c.radius + c.radius * 2.0 * c.height) * 0.5
      case FanCollider:
        // Treat as cylinder for air resistance
        cross_section = (math.PI * c.radius * c.radius + c.radius * 2.0 * c.height) * 0.5
      case:
        // Fallback: estimate from mass (objects with same mass are assumed same size)
        cross_section = math.pow(body.mass, 2.0 / 3.0) * 0.1
      }
    }
    drag_magnitude := 0.5 * physics.air_density * vel_mag * vel_mag * body.drag_coefficient * cross_section
    drag_direction := -linalg.normalize(body.velocity)
    drag_force := drag_direction * drag_magnitude
    // clamp drag acceleration to prevent numerical instability
    // without this, ultra-light objects with large colliders experience extreme deceleration
    // that can cause velocity to explode or reverse in a single timestep
    drag_accel := drag_magnitude * body.inv_mass
    max_accel := linalg.length(physics.gravity) * 30.0
    if drag_accel > max_accel {
      drag_force *= max_accel / drag_accel
    }
    rigid_body_apply_force(body, drag_force)
  }
  // Integrate velocities from forces ONCE for the entire frame
  for &entry in physics.bodies.entries do if entry.active {
    body := &entry.item
    rigid_body_integrate(body, dt)
  }
  // Track which bodies were handled by CCD (outside substep loop)
  ccd_handled := make(
    [dynamic]bool,
    len(physics.bodies.entries),
    context.temp_allocator,
  )
  // Perform CCD for fast-moving objects ONCE before substeps
  ccd_threshold :: 5.0 // Objects moving faster than this use CCD (m/s)
  for &entry_a, idx_a in physics.bodies.entries do if entry_a.active {
    body_a := &entry_a.item
    if body_a.is_static || body_a.collider_handle.generation == 0 || body_a.trigger_only {
      continue
    }
    // Check if moving fast enough for CCD
    velocity_mag := linalg.length(body_a.velocity)
    if velocity_mag < ccd_threshold {
      continue
    }
    node_a := cont.get(w.nodes, body_a.node_handle) or_continue
    collider_a := cont.get(physics.colliders, body_a.collider_handle) or_continue
    pos_a := node_a.transform.position
    motion := body_a.velocity * dt
    earliest_toi := f32(1.0)
    earliest_normal := linalg.VECTOR3F32_Y_AXIS
    earliest_body_b: ^RigidBody = nil
    has_ccd_hit := false
    // Check against all other colliders
    for &entry_b, idx_b in physics.bodies.entries do if entry_b.active {
      if idx_a == idx_b do continue
      body_b := &entry_b.item
      if body_b.collider_handle.generation == 0 do continue
      node_b := cont.get(w.nodes, body_b.node_handle) or_continue
      collider_b := cont.get(physics.colliders, body_b.collider_handle) or_continue
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
      vel_along_normal := linalg.dot(body_a.velocity, earliest_normal)
      if vel_along_normal < 0 {
        // Calculate restitution
        restitution := body_a.restitution
        if earliest_body_b != nil {
          restitution = (body_a.restitution + earliest_body_b.restitution) * 0.5
        }
        // Reflect normal component with restitution
        body_a.velocity -= earliest_normal * vel_along_normal * (1.0 + restitution)
        // Apply friction to tangent velocity
        friction := body_a.friction
        if earliest_body_b != nil {
          friction = (body_a.friction + earliest_body_b.friction) * 0.5
        }
        tangent_vel := body_a.velocity - earliest_normal * linalg.dot(body_a.velocity, earliest_normal)
        body_a.velocity -= tangent_vel * friction * 0.5
      }
      // Mark as handled by CCD - skip normal position integration
      ccd_handled[idx_a] = true
    }
  }
  // integrate position multiple times per frame
  // more substeps = smaller steps = less tunneling through thin objects
  NUM_SUBSTEPS :: 5
  substep_dt := dt / f32(NUM_SUBSTEPS)
  active_body_count := 0
  for &entry in physics.bodies.entries do if entry.active {
    if entry.item.collider_handle.generation != 0 {
      active_body_count += 1
    }
  }
  // Rebuild BVH only when body count changes (bodies added/removed)
  rebuild_bvh := len(physics.spatial_index.primitives) != active_body_count
  bvh_build_time: time.Duration
  if rebuild_bvh {
    bvh_build_start := time.now()
    clear(&physics.spatial_index.nodes)
    clear(&physics.spatial_index.primitives)
    entries := make(
      [dynamic]BroadPhaseEntry,
      0,
      active_body_count,
      context.temp_allocator,
    )
    for &entry, idx in physics.bodies.entries do if entry.active {
      body := &entry.item
      if body.collider_handle.generation == 0 do continue
      node := cont.get(w.nodes, body.node_handle) or_continue
      collider := cont.get(physics.colliders, body.collider_handle) or_continue
      pos := node.transform.position
      bounds := collider_get_aabb(collider, pos)
      handle := resources.Handle {
        index      = u32(idx),
        generation = entry.generation,
      }
      append(&entries, BroadPhaseEntry{handle = handle, bounds = bounds})
    }
    geometry.bvh_build(&physics.spatial_index, entries[:], 4)
    bvh_build_time = time.since(bvh_build_start)
  }
  substep_start := time.now()
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  defer delete(candidates)
  for substep in 0 ..< NUM_SUBSTEPS {
    // clear and redetect contacts at current positions
    clear(&physics.contacts)
    for &bvh_entry, i in physics.spatial_index.primitives {
      body := cont.get(physics.bodies, bvh_entry.handle) or_continue
      node := cont.get(w.nodes, body.node_handle) or_continue
      collider := cont.get(physics.colliders, body.collider_handle) or_continue
      pos := node.transform.position
      bvh_entry.bounds = collider_get_aabb(collider, pos)
    }
    geometry.bvh_refit(&physics.spatial_index)
    for &bvh_entry in physics.spatial_index.primitives {
      handle_a := bvh_entry.handle
      body_a := cont.get(physics.bodies, handle_a) or_continue
      clear(&candidates)
      geometry.bvh_query_aabb(
        &physics.spatial_index,
        bvh_entry.bounds,
        &candidates,
      )
      for entry_b in candidates {
        handle_b := entry_b.handle
        // Skip self-collision
        if handle_a == handle_b do continue
        // Skip duplicate pairs (only test A-B, not B-A)
        if handle_a.index > handle_b.index do continue
        body_b := cont.get(physics.bodies, handle_b) or_continue
        if body_a.is_static && body_b.is_static do continue
        // Skip collision resolution if either body is trigger_only
        if body_a.trigger_only || body_b.trigger_only do continue
        if body_a.collider_handle.generation == 0 ||
           body_b.collider_handle.generation == 0 {
          continue
        }
        node_a := cont.get(w.nodes, body_a.node_handle) or_continue
        node_b := cont.get(w.nodes, body_b.node_handle) or_continue
        collider_a := cont.get(
          physics.colliders,
          body_a.collider_handle,
        ) or_continue
        collider_b := cont.get(
          physics.colliders,
          body_b.collider_handle,
        ) or_continue
        pos_a := node_a.transform.position
        pos_b := node_b.transform.position
        // Try fast primitive collision first, fall back to GJK if unavailable
        point, normal, penetration, hit := test_collision(
          collider_a,
          pos_a,
          collider_b,
          pos_b,
        )
        // If primitive test returns no collision but shapes support GJK, try GJK as fallback
        if !hit {
          point, normal, penetration, hit = test_collision_gjk(
            collider_a,
            pos_a,
            collider_b,
            pos_b,
          )
        }
        if !hit do continue
        contact := Contact {
          body_a      = handle_a,
          body_b      = handle_b,
          point       = point,
          normal      = normal,
          penetration = penetration,
          restitution = (body_a.restitution + body_b.restitution) * 0.5,
          friction    = (body_a.friction + body_b.friction) * 0.5,
        }
        // Check if we have a cached contact from previous frame for warmstarting
        pair := CollisionPair {
          body_a = handle_a,
          body_b = handle_b,
        }
        hash := collision_pair_hash(pair)
        if prev_contact, found := physics.prev_contacts[hash]; found {
          // Copy accumulated impulses for warmstart with heavy damping
          // Heavy damping prevents bad impulses from causing instability
          warmstart_coef :: 0.8 // Reduced to prevent carrying forward problematic impulses
          contact.normal_impulse = prev_contact.normal_impulse * warmstart_coef
          contact.tangent_impulse[0] =
            prev_contact.tangent_impulse[0] * warmstart_coef
          contact.tangent_impulse[1] =
            prev_contact.tangent_impulse[1] * warmstart_coef
        }
        append(&physics.contacts, contact)
      }
    }
    // Prepare all contacts (compute mass matrices and bias terms)
    for &contact in physics.contacts {
      body_a := cont.get(physics.bodies, contact.body_a) or_continue
      body_b := cont.get(physics.bodies, contact.body_b) or_continue
      node_a := cont.get(w.nodes, body_a.node_handle) or_continue
      node_b := cont.get(w.nodes, body_b.node_handle) or_continue
      pos_a := node_a.transform.position
      pos_b := node_b.transform.position
      prepare_contact(&contact, body_a, body_b, pos_a, pos_b, substep_dt)
    }
    // Warmstart with cached impulses (only on first substep)
    if substep == 0 {
      for &contact in physics.contacts {
        body_a := cont.get(physics.bodies, contact.body_a) or_continue
        body_b := cont.get(physics.bodies, contact.body_b) or_continue
        node_a := cont.get(w.nodes, body_a.node_handle) or_continue
        node_b := cont.get(w.nodes, body_b.node_handle) or_continue
        pos_a := node_a.transform.position
        pos_b := node_b.transform.position
        warmstart_contact(&contact, body_a, body_b, pos_a, pos_b)
      }
    }
    // Solve constraints with bias (includes position correction + restitution)
    for _ in 0 ..< physics.iterations {
      for &contact in physics.contacts {
        body_a := cont.get(physics.bodies, contact.body_a) or_continue
        body_b := cont.get(physics.bodies, contact.body_b) or_continue
        node_a := cont.get(w.nodes, body_a.node_handle) or_continue
        node_b := cont.get(w.nodes, body_b.node_handle) or_continue
        pos_a := node_a.transform.position
        pos_b := node_b.transform.position
        resolve_contact(&contact, body_a, body_b, pos_a, pos_b)
      }
    }
    // Additional stabilization iterations WITHOUT bias (pure constraint enforcement)
    // This prevents jitter without adding artificial velocity
    stabilization_iters :: 2
    for _ in 0 ..< stabilization_iters {
      for &contact in physics.contacts {
        body_a := cont.get(physics.bodies, contact.body_a) or_continue
        body_b := cont.get(physics.bodies, contact.body_b) or_continue
        node_a := cont.get(w.nodes, body_a.node_handle) or_continue
        node_b := cont.get(w.nodes, body_b.node_handle) or_continue
        pos_a := node_a.transform.position
        pos_b := node_b.transform.position
        // Solve without bias - only enforce zero relative velocity at contact
        resolve_contact_no_bias(&contact, body_a, body_b, pos_a, pos_b)
      }
    }
    for &entry, idx in physics.bodies.entries do if entry.active {
      body := &entry.item
      if body.is_static || body.is_kinematic || body.trigger_only {
        continue
      }
      // Skip if already handled by CCD
      if idx < len(ccd_handled) && ccd_handled[idx] {
        continue
      }
      node := cont.get(w.nodes, body.node_handle) or_continue
      // Update position using substep timestep
      vel := body.velocity * substep_dt
      geometry.transform_translate_by(&node.transform, vel.x, vel.y, vel.z)
      // Update rotation from angular velocity (if enabled)
      // Use quaternion integration: q_new = q_old + 0.5 * dt * (omega * q_old)
      // Skip rotation if angular velocity is negligible or rotation is disabled
      if !body.enable_rotation do continue
      ang_vel_mag_sq := linalg.length2(body.angular_velocity)
      if ang_vel_mag_sq < math.F32_EPSILON do continue
      // Create pure quaternion from angular velocity (w=0, xyz=angular_velocity)
      omega_quat := quaternion(w = 0, x = body.angular_velocity.x, y = body.angular_velocity.y, z = body.angular_velocity.z)
      q_old := node.transform.rotation
      // Calculate derivative: q_dot = 0.5 * omega * q_old
      q_dot := omega_quat * q_old
      q_dot.w *= 0.5
      q_dot.x *= 0.5
      q_dot.y *= 0.5
      q_dot.z *= 0.5
      // Integrate: q_new = q_old + q_dot * substep_dt
      q_new := quaternion(w = q_old.w + q_dot.w * substep_dt, x = q_old.x + q_dot.x * substep_dt, y = q_old.y + q_dot.y * substep_dt, z = q_old.z + q_dot.z * substep_dt)
      // Normalize to prevent drift
      q_new = linalg.normalize(q_new)
      geometry.transform_rotate(&node.transform, q_new)
    }
  }
  substep_time := time.since(substep_start)
  for &entry, idx in physics.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_static || body.is_kinematic {
      continue
    }
    node := cont.get(w.nodes, body.node_handle) or_continue
    if node.transform.position.y < KILL_Y {
      handle := resources.Handle {
        index      = u32(idx),
        generation = entry.generation,
      }
      defer destroy_body(physics, handle)
      body := cont.get(physics.bodies, handle) or_continue
      node, _ := cont.get(w.nodes, body.node_handle)
      log.infof("Removing body at y=%.2f (below KILL_Y=%.2f)", node.transform.position.y, KILL_Y)
    }
  }
  total_time := time.since(step_start)
  log.infof(
    "Physics: %.2fms total | BVH build=%.2fms | substeps=%.2fms | bodies=%d contacts=%d",
    time.duration_milliseconds(total_time),
    time.duration_milliseconds(bvh_build_time),
    time.duration_milliseconds(substep_time),
    active_body_count,
    len(physics.contacts),
  )
}
