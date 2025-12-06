package physics

import cont "../containers"
import "../geometry"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:thread"
import "core:time"

KILL_Y :: #config(PHYSICS_KILL_Y, -50.0)
SEA_LEVEL_AIR_DENSITY :: 1.225
NUM_SUBSTEPS :: 2
CONSTRAINT_SOLVER_ITERS :: 1
STABILIZATION_ITERS :: 1

RigidBodyHandle :: distinct cont.Handle
ColliderHandle :: distinct cont.Handle

World :: struct {
  bodies:                resources.Pool(RigidBody),
  colliders:             resources.Pool(Collider),
  contacts:              [dynamic]Contact,
  prev_contacts:         map[u64]Contact, // Contact cache for warmstarting
  gravity:               [3]f32,
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
  self: ^World,
  gravity := [3]f32{0, -9.81, 0},
  enable_parallel: bool = true,
) {
  cont.init(&self.bodies)
  cont.init(&self.colliders)
  self.contacts = make([dynamic]Contact)
  self.prev_contacts = make(map[u64]Contact)
  self.gravity = gravity
  self.spatial_index = geometry.BVH(BroadPhaseEntry) {
    nodes = make([dynamic]geometry.BVHNode),
    primitives = make([dynamic]BroadPhaseEntry),
    bounds_func = proc(entry: BroadPhaseEntry) -> geometry.Aabb {
      return entry.bounds
    },
  }
  self.body_bounds = make([dynamic]geometry.Aabb)
  self.enable_air_resistance = false
  self.air_density = SEA_LEVEL_AIR_DENSITY
  self.enable_parallel = enable_parallel
  if self.enable_parallel {
    self.thread_count = DEFAULT_THREAD_COUNT
    thread.pool_init(
      &self.thread_pool,
      context.allocator,
      DEFAULT_THREAD_COUNT,
    )
    thread.pool_start(&self.thread_pool)
    self.thread_pool_running = true
  }
}

destroy :: proc(self: ^World) {
  if self.thread_pool_running {
    thread.pool_destroy(&self.thread_pool)
    self.thread_pool_running = false
  }
  cont.destroy(self.bodies, proc(body: ^RigidBody) {})
  cont.destroy(self.colliders, proc(col: ^Collider) {})
  delete(self.body_bounds)
  delete(self.contacts)
  delete(self.prev_contacts)
  geometry.bvh_destroy(&self.spatial_index)
}

create_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  is_static: bool = false,
  trigger_only: bool = false,
) -> (
  handle: RigidBodyHandle,
  ok: bool,
) #optional_ok {
  body: ^RigidBody
  handle, body = cont.alloc(&self.bodies, RigidBodyHandle) or_return
  rigid_body_init(body, position, rotation, mass, is_static)
  body.trigger_only = trigger_only
  return handle, true
}

destroy_body :: proc(self: ^World, handle: RigidBodyHandle) {
  if body, ok := cont.get(self.bodies, handle); ok {
    cont.free(&self.colliders, body.collider_handle)
  }
  cont.free(&self.bodies, handle)
}

create_collider_sphere :: proc(
  self: ^World,
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
  self: ^World,
  body_handle: RigidBodyHandle,
  half_extents: [3]f32,
  offset: [3]f32 = {},
) -> (
  handle: ColliderHandle,
  ok: bool,
) #optional_ok {
  ptr: ^Collider
  handle, ptr = cont.alloc(&self.colliders, ColliderHandle) or_return
  ptr.offset = offset
  ptr.shape = BoxCollider {
    half_extents = half_extents,
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true
}

create_collider_capsule :: proc(
  self: ^World,
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
  self: ^World,
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
  ptr.shape = CylinderCollider {
    radius   = radius,
    height   = height,
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true
}

create_collider_fan :: proc(
  self: ^World,
  body_handle: RigidBodyHandle,
  radius: f32,
  height: f32,
  angle: f32,
  offset: [3]f32 = {},
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
  }
  if body, ok := cont.get(self.bodies, body_handle); ok {
    body.collider_handle = handle
  }
  return handle, true
}

create_body_sphere :: proc(
  self: ^World,
  radius: f32 = 1.0,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  is_static: bool = false,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: RigidBodyHandle,
  ok: bool,
) #optional_ok {
  body_handle = create_body(
    self,
    position,
    rotation,
    mass,
    is_static,
    trigger_only,
  ) or_return
  _ = create_collider_sphere(
    self,
    body_handle,
    radius,
    offset,
  ) or_return
  return body_handle, true
}

create_body_box :: proc(
  self: ^World,
  half_extents: [3]f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  is_static: bool = false,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: RigidBodyHandle,
  ok: bool,
) #optional_ok {
  body_handle = create_body(
    self,
    position,
    rotation,
    mass,
    is_static,
    trigger_only,
  ) or_return
  _ = create_collider_box(
    self,
    body_handle,
    half_extents,
    offset,
  ) or_return
  return body_handle, true
}

create_body_capsule :: proc(
  self: ^World,
  radius: f32,
  height: f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  is_static: bool = false,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: RigidBodyHandle,
  ok: bool,
) #optional_ok {
  body_handle = create_body(
    self,
    position,
    rotation,
    mass,
    is_static,
    trigger_only,
  ) or_return
  _ = create_collider_capsule(
    self,
    body_handle,
    radius,
    height,
    offset,
  ) or_return
  return body_handle, true
}

create_body_cylinder :: proc(
  self: ^World,
  radius: f32,
  height: f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  is_static: bool = false,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: RigidBodyHandle,
  ok: bool,
) #optional_ok {
  body_handle = create_body(
    self,
    position,
    rotation,
    mass,
    is_static,
    trigger_only,
  ) or_return
  _ = create_collider_cylinder(
    self,
    body_handle,
    radius,
    height,
    offset,
  ) or_return
  return body_handle, true
}

create_body_fan :: proc(
  self: ^World,
  radius: f32,
  height: f32,
  angle: f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  is_static: bool = false,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: RigidBodyHandle,
  ok: bool,
) #optional_ok {
  body_handle = create_body(
    self,
    position,
    rotation,
    mass,
    is_static,
    trigger_only,
  ) or_return
  _ = create_collider_fan(
    self,
    body_handle,
    radius,
    height,
    angle,
    offset,
  ) or_return
  return body_handle, true
}

step :: proc(self: ^World, dt: f32) {
  step_start := time.now()
  @(static) frame_counter := 0
  frame_counter += 1
  // Save previous contacts for warmstarting
  warmstart_prep_start := time.now()
  clear(&self.prev_contacts)
  for contact in self.contacts {
    hash := collision_pair_hash({contact.body_a, contact.body_b})
    self.prev_contacts[hash] = contact
  }
  warmstart_prep_time := time.since(warmstart_prep_start)
  // Apply forces to all bodies (gravity, air resistance, etc.)
  force_application_start := time.now()
  awake_body_count := 0
  for &entry, idx in self.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_static || body.is_kinematic || body.trigger_only {
      continue
    }
    awake_body_count += 1
    // Apply gravity
    gravity_force := self.gravity * body.mass * body.gravity_scale
    apply_force(body, gravity_force)
    if !self.enable_air_resistance do continue
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
      collider := cont.get(self.colliders, body.collider_handle) or_break calculate_cross_section
      // Estimate frontal area based on collider type
      switch c in collider.shape {
      case SphereCollider:
        cross_section = math.PI * c.radius * c.radius
      case CapsuleCollider:
        cross_section = math.PI * c.radius * c.radius
      case BoxCollider:
        // Frontal area of box (average of three face areas)
        cross_section = (c.half_extents.x * c.half_extents.y + c.half_extents.y * c.half_extents.z + c.half_extents.x * c.half_extents.z) * 4.0 / 3.0
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
    drag_magnitude := 0.5 * self.air_density * vel_mag * vel_mag * body.drag_coefficient * cross_section
    drag_direction := -linalg.normalize(body.velocity)
    drag_force := drag_direction * drag_magnitude
    // clamp drag acceleration to prevent numerical instability
    // without this, ultra-light objects with large colliders experience extreme deceleration
    // that can cause velocity to explode or reverse in a single timestep
    drag_accel := drag_magnitude * body.inv_mass
    max_accel := linalg.length(self.gravity) * 30.0
    if drag_accel > max_accel {
      drag_force *= max_accel / drag_accel
    }
    apply_force(body, drag_force)
  }
  force_application_time := time.since(force_application_start)
  // Integrate velocities from forces ONCE for the entire frame
  integration_start := time.now()
  for &entry, idx in self.bodies.entries do if entry.active {
    body := &entry.item
    integrate(body, dt)
  }
  integration_time := time.since(integration_start)
  // Track which bodies were handled by CCD (outside substep loop)
  ccd_start := time.now()
  ccd_handled := make(
    [dynamic]bool,
    len(self.bodies.entries),
    context.temp_allocator,
  )
  ccd_bodies_tested, ccd_total_candidates := 0, 0
  if self.enable_parallel {
    ccd_bodies_tested, ccd_total_candidates = parallel_ccd(
      self,
      dt,
      ccd_handled[:],
      self.thread_count,
    )
  } else {
    ccd_bodies_tested, ccd_total_candidates = sequential_ccd(
      self,
      dt,
      ccd_handled[:],
    )
  }
  ccd_time := time.since(ccd_start)
  // integrate position multiple times per frame
  // more substeps = smaller steps = less tunneling through thin objects
  substep_dt := dt / f32(NUM_SUBSTEPS)
  active_body_count := 0
  for &entry, idx in self.bodies.entries do if entry.active {
    if entry.item.collider_handle.generation != 0 {
      active_body_count += 1
    }
  }
  // Rebuild BVH only when body count changes (bodies added/removed)
  rebuild_bvh := len(self.spatial_index.primitives) != active_body_count
  bvh_build_time: time.Duration
  if rebuild_bvh {
    bvh_build_start := time.now()
    clear(&self.spatial_index.nodes)
    clear(&self.spatial_index.primitives)
    entries := make(
      [dynamic]BroadPhaseEntry,
      0,
      active_body_count,
      context.temp_allocator,
    )
    for &entry, idx in self.bodies.entries do if entry.active {
      body := &entry.item
      if body.collider_handle.generation == 0 do continue
      collider := cont.get(self.colliders, body.collider_handle) or_continue
      update_cached_aabb(body, collider)
      handle := RigidBodyHandle {
        index      = u32(idx),
        generation = entry.generation,
      }
      append(&entries, BroadPhaseEntry{handle = handle, bounds = body.cached_aabb})
    }
    geometry.bvh_build(&self.spatial_index, entries[:], 4)
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
    clear(&self.contacts)
    if self.enable_parallel {
      parallel_bvh_refit(self, self.thread_count)
    } else {
      sequential_bvh_refit(self)
    }
    refit_time += time.since(refit_start)
    broadphase_start := time.now()
    if self.enable_parallel {
      parallel_collision_detection(self, self.thread_count)
    } else {
      sequential_collision_detection(self)
    }
    collision_time := time.since(broadphase_start)
    broadphase_time += collision_time
    narrowphase_time += collision_time
    // Prepare all contacts (compute mass matrices and bias terms)
    prepare_start := time.now()
    for &contact in self.contacts {
      body_a := cont.get(self.bodies, contact.body_a) or_continue
      body_b := cont.get(self.bodies, contact.body_b) or_continue
      prepare_contact(&contact, body_a, body_b, substep_dt)
    }
    prepare_time += time.since(prepare_start)
    // Warmstart with cached impulses (only on first substep)
    solver_start := time.now()
    if substep == 0 {
      for &contact in self.contacts {
        body_a := cont.get(self.bodies, contact.body_a) or_continue
        body_b := cont.get(self.bodies, contact.body_b) or_continue
        warmstart_contact(&contact, body_a, body_b)
      }
    }
    // Solve constraints with bias (includes position correction + restitution)
    #unroll for _ in 0 ..< CONSTRAINT_SOLVER_ITERS {
      for &contact in self.contacts {
        body_a := cont.get(self.bodies, contact.body_a) or_continue
        body_b := cont.get(self.bodies, contact.body_b) or_continue
        resolve_contact(&contact, body_a, body_b)
      }
    }
    // Additional stabilization iterations WITHOUT bias (pure constraint enforcement)
    // This prevents jitter without adding artificial velocity
    #unroll for _ in 0 ..< STABILIZATION_ITERS {
      for &contact in self.contacts {
        body_a := cont.get(self.bodies, contact.body_a) or_continue
        body_b := cont.get(self.bodies, contact.body_b) or_continue
        // Solve without bias - only enforce zero relative velocity at contact
        resolve_contact_no_bias(&contact, body_a, body_b)
      }
    }
    solver_time += time.since(solver_start)
    integration_start_substep := time.now()
    for &entry, idx in self.bodies.entries do if entry.active {
      body := &entry.item
      if body.is_static || body.is_kinematic || body.trigger_only {
        continue
      }
      // Skip if already handled by CCD
      if idx < len(ccd_handled) && ccd_handled[idx] {
        continue
      }
      // Update position using substep timestep
      vel := body.velocity * substep_dt
      body.position += vel
      // Update rotation from angular velocity (if enabled)
      // Use quaternion integration: q_new = q_old + 0.5 * dt * (omega * q_old)
      // Skip rotation if angular velocity is negligible or rotation is disabled
      if body.enable_rotation {
        ang_vel_mag_sq := linalg.length2(body.angular_velocity)
        if ang_vel_mag_sq >= math.F32_EPSILON {
          // Create pure quaternion from angular velocity (w=0, xyz=angular_velocity)
          omega_quat := quaternion(w = 0, x = body.angular_velocity.x, y = body.angular_velocity.y, z = body.angular_velocity.z)
          q_old := body.rotation
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
          body.rotation = q_new
        }
      }
    }
    integration_time_substep += time.since(integration_start_substep)
  }
  substep_time := time.since(substep_start)
  // Update cached AABBs after all substeps complete
  cache_update_start := time.now()
  if self.enable_parallel {
    parallel_update_aabb_cache(self, self.thread_count)
  } else {
    sequential_update_aabb_cache(self)
  }
  cache_update_time := time.since(cache_update_start)
  cleanup_start := time.now()
  for &entry, idx in self.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_static || body.is_kinematic {
      continue
    }
    if body.position.y < KILL_Y {
      handle := RigidBodyHandle {
        index      = u32(idx),
        generation = entry.generation,
      }
      defer destroy_body(self, handle)
      log.infof("Removing body at y=%.2f (below KILL_Y=%.2f)", body.position.y, KILL_Y)
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
    len(self.contacts),
  )
}

get_body :: proc(
  self: ^World,
  handle: RigidBodyHandle,
) -> (
  ret: ^RigidBody,
  ok: bool,
) #optional_ok {
  return cont.get(self.bodies, handle)
}

get_collider :: proc(
  self: ^World,
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
