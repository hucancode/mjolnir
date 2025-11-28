package physics

import cont "../containers"
import "../geometry"
import "../resources"
import "../world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:thread"
import "core:time"

KILL_Y :: -50.0
SEA_LEVEL_AIR_DENSITY :: 1.225
RigidBodyHandle :: distinct cont.Handle
ColliderHandle :: distinct cont.Handle

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
  enable_parallel:       bool,
  thread_count:          int,
  thread_pool:           thread.Pool,
  thread_pool_running:   bool,
}

BroadPhaseEntry :: struct {
  handle: RigidBodyHandle,
  bounds: geometry.Aabb,
}

init :: proc(
  world: ^PhysicsWorld,
  gravity := [3]f32{0, -9.81, 0},
  enable_parallel: bool = true,
) {
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
  world.air_density = SEA_LEVEL_AIR_DENSITY
  world.enable_parallel = enable_parallel
  if world.enable_parallel {
    world.thread_count = DEFAULT_THREAD_COUNT
    thread.pool_init(
      &world.thread_pool,
      context.allocator,
      DEFAULT_THREAD_COUNT,
    )
    thread.pool_start(&world.thread_pool)
    world.thread_pool_running = true
  }
}

destroy :: proc(world: ^PhysicsWorld) {
  if world.thread_pool_running {
    thread.pool_destroy(&world.thread_pool)
    world.thread_pool_running = false
  }
  cont.destroy(world.bodies, proc(body: ^RigidBody) {})
  cont.destroy(world.colliders, proc(col: ^Collider) {})
  delete(world.body_bounds)
  delete(world.contacts)
  delete(world.prev_contacts)
  geometry.bvh_destroy(&world.spatial_index)
}

create_body :: proc(
  world: ^PhysicsWorld,
  node_handle: resources.NodeHandle,
  mass: f32 = 1.0,
  is_static: bool = false,
  trigger_only: bool = false,
) -> (
  handle: RigidBodyHandle,
  ok: bool,
) #optional_ok {
  body: ^RigidBody
  handle, body = cont.alloc(&world.bodies, RigidBodyHandle) or_return
  rigid_body_init(body, node_handle, mass, is_static)
  body.trigger_only = trigger_only
  return handle, true
}

destroy_body :: proc(world: ^PhysicsWorld, handle: RigidBodyHandle) {
  if body, ok := cont.get(world.bodies, handle); ok {
    cont.free(&world.colliders, body.collider_handle)
  }
  cont.free(&world.bodies, handle)
}

create_collider_sphere :: proc(
  self: ^PhysicsWorld,
  body_handle: RigidBodyHandle,
  radius: f32 = 1.0,
  offset: [3]f32 = {},
) -> (
  handle: ColliderHandle,
  ok: bool,
) #optional_ok {
  ptr: ^Collider
  handle, ptr = cont.alloc(&self.colliders, ColliderHandle) or_return
  ptr.offset = offset
  ptr.shape = SphereCollider {
    radius = radius,
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true

}

create_collider_box :: proc(
  self: ^PhysicsWorld,
  body_handle: RigidBodyHandle,
  half_extents: [3]f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> (
  handle: ColliderHandle,
  ok: bool,
) #optional_ok {
  ptr: ^Collider
  handle, ptr = cont.alloc(&self.colliders, ColliderHandle) or_return
  ptr.offset = offset
  ptr.shape = BoxCollider {
    half_extents = half_extents,
    rotation     = rotation,
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true
}

create_collider_capsule :: proc(
  self: ^PhysicsWorld,
  body_handle: RigidBodyHandle,
  radius: f32,
  height: f32,
  offset: [3]f32 = {},
) -> (
  handle: ColliderHandle,
  ok: bool,
) #optional_ok {
  ptr: ^Collider
  handle, ptr = cont.alloc(&self.colliders, ColliderHandle) or_return
  ptr.offset = offset
  ptr.shape = CapsuleCollider {
    radius = radius,
    height = height,
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true
}

create_collider_cylinder :: proc(
  self: ^PhysicsWorld,
  body_handle: RigidBodyHandle,
  radius: f32,
  height: f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> (
  handle: ColliderHandle,
  ok: bool,
) #optional_ok {
  ptr: ^Collider
  handle, ptr = cont.alloc(&self.colliders, ColliderHandle) or_return
  ptr.offset = offset
  ptr.shape = CylinderCollider {
    radius   = radius,
    height   = height,
    rotation = rotation,
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true
}

create_collider_fan :: proc(
  self: ^PhysicsWorld,
  body_handle: RigidBodyHandle,
  radius: f32,
  height: f32,
  angle: f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> (
  handle: ColliderHandle,
  ok: bool,
) #optional_ok {
  ptr: ^Collider
  handle, ptr = cont.alloc(&self.colliders, ColliderHandle) or_return
  ptr.offset = offset
  ptr.shape = FanCollider {
    radius   = radius,
    height   = height,
    angle    = angle,
    rotation = rotation,
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true
}

step :: proc(physics: ^PhysicsWorld, w: ^world.World, dt: f32) {
  step_start := time.now()
  @(static) frame_counter := 0
  frame_counter += 1
  // Save previous contacts for warmstarting
  warmstart_prep_start := time.now()
  clear(&physics.prev_contacts)
  for contact in physics.contacts {
    hash := collision_pair_hash({contact.body_a, contact.body_b})
    physics.prev_contacts[hash] = contact
  }
  warmstart_prep_time := time.since(warmstart_prep_start)
  // Apply forces to all bodies (gravity, air resistance, etc.)
  force_application_start := time.now()
  awake_body_count := 0
  for &entry, idx in physics.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_static || body.is_kinematic || body.trigger_only {
      continue
    }
    awake_body_count += 1
    // Apply gravity
    gravity_force := physics.gravity * body.mass * body.gravity_scale
    apply_force(body, gravity_force)
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
    apply_force(body, drag_force)
  }
  force_application_time := time.since(force_application_start)
  // Integrate velocities from forces ONCE for the entire frame
  integration_start := time.now()
  for &entry, idx in physics.bodies.entries do if entry.active {
    body := &entry.item
    integrate(body, dt)
  }
  integration_time := time.since(integration_start)
  // Track which bodies were handled by CCD (outside substep loop)
  ccd_start := time.now()
  ccd_handled := make(
    [dynamic]bool,
    len(physics.bodies.entries),
    context.temp_allocator,
  )
  ccd_bodies_tested, ccd_total_candidates := 0, 0
  if physics.enable_parallel {
    ccd_bodies_tested, ccd_total_candidates = parallel_ccd(
      physics,
      w,
      dt,
      ccd_handled[:],
      physics.thread_count,
    )
  } else {
    ccd_bodies_tested, ccd_total_candidates = sequential_ccd(
      physics,
      w,
      dt,
      ccd_handled[:],
    )
  }
  ccd_time := time.since(ccd_start)
  // integrate position multiple times per frame
  // more substeps = smaller steps = less tunneling through thin objects
  NUM_SUBSTEPS :: 1
  substep_dt := dt / f32(NUM_SUBSTEPS)
  active_body_count := 0
  for &entry, idx in physics.bodies.entries do if entry.active {
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
      update_cached_aabb(body, collider, pos)
      handle := RigidBodyHandle {
        index      = u32(idx),
        generation = entry.generation,
      }
      append(&entries, BroadPhaseEntry{handle = handle, bounds = body.cached_aabb})
    }
    geometry.bvh_build(&physics.spatial_index, entries[:], 4)
    bvh_build_time = time.since(bvh_build_start)
  }
  substep_start := time.now()
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  defer delete(candidates)
  refit_time: time.Duration
  broadphase_time: time.Duration
  narrowphase_time: time.Duration
  prepare_time: time.Duration
  solver_time: time.Duration
  integration_time_substep: time.Duration
  #unroll for substep in 0 ..< NUM_SUBSTEPS {
    // clear and redetect contacts at current positions
    refit_start := time.now()
    clear(&physics.contacts)
    if physics.enable_parallel {
      parallel_bvh_refit(physics, w, physics.thread_count)
    } else {
      sequential_bvh_refit(physics, w)
    }
    refit_time += time.since(refit_start)
    broadphase_start := time.now()
    if physics.enable_parallel {
      parallel_collision_detection(physics, w, physics.thread_count)
    } else {
      sequential_collision_detection(physics, w)
    }
    collision_time := time.since(broadphase_start)
    broadphase_time += collision_time
    narrowphase_time += collision_time
    // Prepare all contacts (compute mass matrices and bias terms)
    prepare_start := time.now()
    for &contact in physics.contacts {
      body_a := cont.get(physics.bodies, contact.body_a) or_continue
      body_b := cont.get(physics.bodies, contact.body_b) or_continue
      node_a := cont.get(w.nodes, body_a.node_handle) or_continue
      node_b := cont.get(w.nodes, body_b.node_handle) or_continue
      pos_a := node_a.transform.position
      pos_b := node_b.transform.position
      prepare_contact(&contact, body_a, body_b, pos_a, pos_b, substep_dt)
    }
    prepare_time += time.since(prepare_start)
    // Warmstart with cached impulses (only on first substep)
    solver_start := time.now()
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
    #unroll for _ in 0 ..< stabilization_iters {
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
    solver_time += time.since(solver_start)
    integration_start_substep := time.now()
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
      geometry.translate_by(&node.transform, vel.x, vel.y, vel.z)
      // Update rotation from angular velocity (if enabled)
      // Use quaternion integration: q_new = q_old + 0.5 * dt * (omega * q_old)
      // Skip rotation if angular velocity is negligible or rotation is disabled
      if body.enable_rotation {
        ang_vel_mag_sq := linalg.length2(body.angular_velocity)
        if ang_vel_mag_sq >= math.F32_EPSILON {
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
          geometry.rotate(&node.transform, q_new)
        }
      }
    }
    integration_time_substep += time.since(integration_start_substep)
  }
  substep_time := time.since(substep_start)
  // Update cached AABBs after all substeps complete
  cache_update_start := time.now()
  if physics.enable_parallel {
    parallel_update_aabb_cache(physics, w, physics.thread_count)
  } else {
    sequential_update_aabb_cache(physics, w)
  }
  cache_update_time := time.since(cache_update_start)
  cleanup_start := time.now()
  for &entry, idx in physics.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_static || body.is_kinematic {
      continue
    }
    node := cont.get(w.nodes, body.node_handle) or_continue
    if node.transform.position.y < KILL_Y {
      handle := RigidBodyHandle {
        index      = u32(idx),
        generation = entry.generation,
      }
      defer destroy_body(physics, handle)
      body := cont.get(physics.bodies, handle) or_continue
      node := cont.get(w.nodes, body.node_handle)
      log.infof("Removing body at y=%.2f (below KILL_Y=%.2f)", node.transform.position.y, KILL_Y)
    }
  }
  cleanup_time := time.since(cleanup_start)
  total_time := time.since(step_start)
  avg_candidates :=
    ccd_bodies_tested > 0 ? f32(ccd_total_candidates) / f32(ccd_bodies_tested) : 0.0
  log.infof(
    "Physics: %.2fms total | warmstart=%.2fms force=%.2fms integ=%.2fms ccd=%.2fms (fast=%d avg_cands=%.1f) bvh=%.2fms substeps=%.2fms [refit=%.2fms broad=%.2fms narrow=%.2fms prep=%.2fms solve=%.2fms integ=%.2fms] cleanup=%.2fms | bodies=%d awake=%d contacts=%d",
    time.duration_milliseconds(total_time),
    time.duration_milliseconds(warmstart_prep_time),
    time.duration_milliseconds(force_application_time),
    time.duration_milliseconds(integration_time),
    time.duration_milliseconds(ccd_time),
    ccd_bodies_tested,
    avg_candidates,
    time.duration_milliseconds(bvh_build_time),
    time.duration_milliseconds(substep_time),
    time.duration_milliseconds(refit_time),
    time.duration_milliseconds(broadphase_time),
    time.duration_milliseconds(narrowphase_time),
    time.duration_milliseconds(prepare_time),
    time.duration_milliseconds(solver_time),
    time.duration_milliseconds(integration_time_substep),
    time.duration_milliseconds(cleanup_time),
    active_body_count,
    awake_body_count,
    len(physics.contacts),
  )
}

get_body :: proc(
  self: ^PhysicsWorld,
  handle: RigidBodyHandle,
) -> (
  ret: ^RigidBody,
  ok: bool,
) #optional_ok {
  return cont.get(self.bodies, handle)
}

get_collider :: proc(
  self: ^PhysicsWorld,
  handle: ColliderHandle,
) -> (
  ret: ^Collider,
  ok: bool,
) #optional_ok {
  return cont.get(self.colliders, handle)
}

get :: proc {
  get_body,
  get_collider,
}
