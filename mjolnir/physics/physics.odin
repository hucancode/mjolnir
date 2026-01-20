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
CONSTRAINT_SOLVER_ITERS :: 4
STABILIZATION_ITERS :: 2
SLEEP_LINEAR_THRESHOLD :: 0.05
SLEEP_ANGULAR_THRESHOLD :: 0.05
SLEEP_LINEAR_THRESHOLD_SQ :: SLEEP_LINEAR_THRESHOLD * SLEEP_LINEAR_THRESHOLD
SLEEP_ANGULAR_THRESHOLD_SQ :: SLEEP_ANGULAR_THRESHOLD * SLEEP_ANGULAR_THRESHOLD
SLEEP_TIME_THRESHOLD :: 0.5
ENABLE_VERBOSE_LOG :: false
BVH_REBUILD_THRESHOLD :: #config(PHYSICS_BVH_REBUILD_THRESHOLD, 50) // Rebuild BVH when killed bodies exceed this

DynamicRigidBodyHandle :: distinct cont.Handle
StaticRigidBodyHandle :: distinct cont.Handle
ColliderHandle :: distinct cont.Handle

World :: struct {
  bodies:                resources.Pool(DynamicRigidBody),
  static_bodies:         resources.Pool(StaticRigidBody),
  colliders:             resources.Pool(Collider),
  dynamic_contacts:      [dynamic]DynamicContact,
  static_contacts:       [dynamic]StaticContact,
  prev_dynamic_contacts: map[u64]DynamicContact,
  prev_static_contacts:  map[u64]StaticContact,
  gravity:               [3]f32,
  gravity_magnitude:     f32,
  dynamic_bvh:           geometry.BVH(DynamicBroadPhaseEntry),
  static_bvh:            geometry.BVH(StaticBroadPhaseEntry),
  body_bounds:           [dynamic]geometry.Aabb,
  enable_air_resistance: bool,
  air_density:           f32,
  enable_parallel:       bool,
  thread_count:          int,
  thread_pool:           thread.Pool,
  // Deferred body removal tracking
  killed_body_count:     int,
  // BVH rebuild tracking
  last_dynamic_count:    int,
  last_static_count:     int,
}

DynamicBroadPhaseEntry :: struct {
  handle: DynamicRigidBodyHandle,
  bounds: geometry.Aabb,
}

StaticBroadPhaseEntry :: struct {
  handle: StaticRigidBodyHandle,
  bounds: geometry.Aabb,
}

init :: proc(
  self: ^World,
  gravity := [3]f32{0, -9.81, 0},
  enable_parallel: bool = true,
) {
  cont.init(&self.bodies)
  cont.init(&self.static_bodies)
  cont.init(&self.colliders)
  self.dynamic_contacts = make([dynamic]DynamicContact)
  self.static_contacts = make([dynamic]StaticContact)
  self.prev_dynamic_contacts = make(map[u64]DynamicContact)
  self.prev_static_contacts = make(map[u64]StaticContact)
  self.gravity = gravity
  self.gravity_magnitude = linalg.length(gravity)
  self.dynamic_bvh = geometry.BVH(DynamicBroadPhaseEntry) {
    nodes = make([dynamic]geometry.BVHNode),
    primitives = make([dynamic]DynamicBroadPhaseEntry),
    bounds_func = #force_inline proc(
      entry: DynamicBroadPhaseEntry,
    ) -> geometry.Aabb {
      return entry.bounds
    },
  }
  self.static_bvh = geometry.BVH(StaticBroadPhaseEntry) {
    nodes = make([dynamic]geometry.BVHNode),
    primitives = make([dynamic]StaticBroadPhaseEntry),
    bounds_func = #force_inline proc(
      entry: StaticBroadPhaseEntry,
    ) -> geometry.Aabb {
      return entry.bounds
    },
  }
  self.body_bounds = make([dynamic]geometry.Aabb)
  self.enable_air_resistance = false
  self.air_density = SEA_LEVEL_AIR_DENSITY
  self.enable_parallel = enable_parallel
  self.killed_body_count = 0
  self.last_dynamic_count = 0
  self.last_static_count = 0
  if self.enable_parallel {
    self.thread_count = DEFAULT_THREAD_COUNT
    thread.pool_init(
      &self.thread_pool,
      context.allocator,
      DEFAULT_THREAD_COUNT,
    )
    thread.pool_start(&self.thread_pool)
    log.infof(
      "Physics.init: Thread pool started - running=%v, threads=%d",
      self.thread_pool.is_running,
      len(self.thread_pool.threads),
    )
  }
}

destroy :: proc(self: ^World) {
  if self.enable_parallel {
    log.infof(
      "Physics.destroy: Destroying thread pool - running=%v, threads=%d",
      self.thread_pool.is_running,
      len(self.thread_pool.threads),
    )
    thread.pool_destroy(&self.thread_pool)
  }
  cont.destroy(self.bodies, proc(body: ^DynamicRigidBody) {})
  cont.destroy(self.static_bodies, proc(body: ^StaticRigidBody) {})
  cont.destroy(self.colliders, proc(col: ^Collider) {})
  delete(self.body_bounds)
  delete(self.dynamic_contacts)
  delete(self.static_contacts)
  delete(self.prev_dynamic_contacts)
  delete(self.prev_static_contacts)
  geometry.bvh_destroy(&self.dynamic_bvh)
  geometry.bvh_destroy(&self.static_bvh)
}

create_dynamic_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  trigger_only: bool = false,
  collider_handle: ColliderHandle = {},
) -> (
  handle: DynamicRigidBodyHandle,
  ok: bool,
) #optional_ok {
  body: ^DynamicRigidBody
  handle, body = cont.alloc(&self.bodies, DynamicRigidBodyHandle) or_return
  rigid_body_init(body, position, rotation, mass)
  body.trigger_only = trigger_only
  body.collider_handle = collider_handle
  return handle, true
}

create_static_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  trigger_only: bool = false,
  collider_handle: ColliderHandle = {},
) -> (
  handle: StaticRigidBodyHandle,
  ok: bool,
) #optional_ok {
  body: ^StaticRigidBody
  handle, body = cont.alloc(
    &self.static_bodies,
    StaticRigidBodyHandle,
  ) or_return
  static_rigid_body_init(body, position, rotation, trigger_only)
  body.collider_handle = collider_handle
  return handle, true
}

destroy_dynamic_body :: proc(self: ^World, handle: DynamicRigidBodyHandle) {
  cont.free(&self.bodies, handle)
}

destroy_static_body :: proc(self: ^World, handle: StaticRigidBodyHandle) {
  cont.free(&self.static_bodies, handle)
}

destroy_body :: proc {
  destroy_dynamic_body,
  destroy_static_body,
}

destroy_collider :: proc(self: ^World, handle: ColliderHandle) {
  cont.free(&self.colliders, handle)
}

create_collider_sphere :: proc(
  self: ^World,
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
  ptr.cross_sectional_area = math.PI * radius * radius
  return handle, true
}

create_collider_box :: proc(
  self: ^World,
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
  ptr.cross_sectional_area =
    (half_extents.x * half_extents.y +
      half_extents.y * half_extents.z +
      half_extents.x * half_extents.z) *
    4.0 /
    3.0
  return handle, true
}

create_collider_cylinder :: proc(
  self: ^World,
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
    radius = radius,
    height = height,
  }
  ptr.cross_sectional_area = math.PI * radius * radius + radius * height
  return handle, true
}

create_collider_fan :: proc(
  self: ^World,
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
    radius = radius,
    height = height,
    angle  = angle,
  }
  ptr.cross_sectional_area = math.PI * radius * radius + radius * height
  return handle, true
}

create_dynamic_body_sphere :: proc(
  self: ^World,
  radius: f32 = 1.0,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: DynamicRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_sphere(self, radius, offset) or_return
  body_handle = create_dynamic_body(
    self,
    position,
    rotation,
    mass,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

create_static_body_sphere :: proc(
  self: ^World,
  radius: f32 = 1.0,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: StaticRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_sphere(self, radius, offset) or_return
  body_handle = create_static_body(
    self,
    position,
    rotation,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

create_dynamic_body_box :: proc(
  self: ^World,
  half_extents: [3]f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: DynamicRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_box(self, half_extents, offset) or_return
  body_handle = create_dynamic_body(
    self,
    position,
    rotation,
    mass,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

create_static_body_box :: proc(
  self: ^World,
  half_extents: [3]f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: StaticRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_box(self, half_extents, offset) or_return
  body_handle = create_static_body(
    self,
    position,
    rotation,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

create_dynamic_body_cylinder :: proc(
  self: ^World,
  radius: f32,
  height: f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: DynamicRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_cylinder(
    self,
    radius,
    height,
    offset,
  ) or_return
  body_handle = create_dynamic_body(
    self,
    position,
    rotation,
    mass,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

create_static_body_cylinder :: proc(
  self: ^World,
  radius: f32,
  height: f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: StaticRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_cylinder(
    self,
    radius,
    height,
    offset,
  ) or_return
  body_handle = create_static_body(
    self,
    position,
    rotation,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

create_dynamic_body_fan :: proc(
  self: ^World,
  radius: f32,
  height: f32,
  angle: f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: DynamicRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_fan(
    self,
    radius,
    height,
    angle,
    offset,
  ) or_return
  body_handle = create_dynamic_body(
    self,
    position,
    rotation,
    mass,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

create_static_body_fan :: proc(
  self: ^World,
  radius: f32,
  height: f32,
  angle: f32,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  trigger_only: bool = false,
  offset: [3]f32 = {},
) -> (
  body_handle: StaticRigidBodyHandle,
  ok: bool,
) #optional_ok {
  collider_handle := create_collider_fan(
    self,
    radius,
    height,
    angle,
    offset,
  ) or_return
  body_handle = create_static_body(
    self,
    position,
    rotation,
    trigger_only,
    collider_handle,
  ) or_return
  return body_handle, true
}

step :: proc(self: ^World, dt: f32) {
  step_start := time.now()
  @(static) frame_counter := 0
  frame_counter += 1
  // Save previous contacts for warmstarting
  warmstart_prep_start := time.now()
  clear(&self.prev_dynamic_contacts)
  clear(&self.prev_static_contacts)
  for contact in self.dynamic_contacts {
    hash := collision_pair_hash(contact.body_a, contact.body_b)
    self.prev_dynamic_contacts[hash] = contact
  }
  for contact in self.static_contacts {
    hash := collision_pair_hash(contact.body_a, contact.body_b)
    self.prev_static_contacts[hash] = contact
  }
  warmstart_prep_time := time.since(warmstart_prep_start)

  // Sleep Update
  for &entry in self.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_killed || body.is_kinematic || body.trigger_only do continue
    lin_speed_sq := linalg.length2(body.velocity)
    ang_speed_sq := linalg.length2(body.angular_velocity)
    if lin_speed_sq < SLEEP_LINEAR_THRESHOLD_SQ && ang_speed_sq < SLEEP_ANGULAR_THRESHOLD_SQ {
      body.sleep_timer += dt
    } else {
      body.sleep_timer = 0
      body.is_sleeping = false
    }
    if body.sleep_timer > SLEEP_TIME_THRESHOLD {
      body.is_sleeping = true
      body.velocity = {}
      body.angular_velocity = {}
    }
  }

  // Apply forces to all bodies (gravity, air resistance, etc.)
  force_application_start := time.now()
  awake_body_count := 0
  for &entry, idx in self.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_killed || body.is_kinematic || body.trigger_only do continue
    if body.is_sleeping do continue
    awake_body_count += 1
    gravity_force := self.gravity * body.mass * body.gravity_scale
    apply_force(body, gravity_force)
    if !self.enable_air_resistance do continue
    vel_mag_sq := linalg.length2(body.velocity)
    if vel_mag_sq < 0.000001 do continue // 0.001^2
    collider := get(self, body.collider_handle) or_continue
    cross_section := collider.cross_sectional_area
    vel_mag := math.sqrt(vel_mag_sq)
    drag_magnitude := 0.5 * self.air_density * vel_mag_sq * body.drag_coefficient * cross_section
    drag_direction := body.velocity * (-1.0 / vel_mag) // reuse vel_mag, avoid normalize
    drag_force := drag_direction * drag_magnitude
    drag_accel := drag_magnitude * body.inv_mass
    max_accel := self.gravity_magnitude * 30.0 // use cached gravity magnitude
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
    if body.is_killed || body.is_sleeping do continue
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
  substep_dt := dt / f32(NUM_SUBSTEPS)
  dynamic_body_count := 0
  for &entry in self.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_killed || body.collider_handle.generation == 0 do continue
    dynamic_body_count += 1
  }
  static_body_count := 0
  for &entry in self.static_bodies.entries do if entry.active {
    if entry.item.collider_handle.generation != 0 {
      static_body_count += 1
    }
  }
  // Rebuild dynamic BVH when NOT batching AND either:
  // 1. New primitives were spawned (count increased)
  // 2. Killed bodies crossed threshold (need cleanup)
  has_new_dynamic := dynamic_body_count > self.last_dynamic_count
  needs_dynamic_cleanup := self.killed_body_count >= BVH_REBUILD_THRESHOLD
  rebuild_dynamic_bvh := has_new_dynamic || needs_dynamic_cleanup
  // Rebuild static BVH when NOT batching AND new static objects were added
  has_new_static := static_body_count > self.last_static_count
  rebuild_static_bvh := has_new_static
  bvh_build_time: time.Duration
  if rebuild_dynamic_bvh {
    bvh_build_start := time.now()
    clear(&self.dynamic_bvh.nodes)
    clear(&self.dynamic_bvh.primitives)
    entries := make(
      [dynamic]DynamicBroadPhaseEntry,
      0,
      dynamic_body_count,
      context.temp_allocator,
    )
    // Destroy killed bodies and rebuild BVH with remaining bodies
    for &entry, idx in self.bodies.entries do if entry.active {
      body := &entry.item
      if body.is_killed {
        // Actually destroy killed bodies during BVH rebuild
        handle := DynamicRigidBodyHandle {
          index      = u32(idx),
          generation = entry.generation,
        }
        destroy_body(self, handle)
        continue
      }
      if body.collider_handle.generation == 0 do continue
      collider := get(self, body.collider_handle) or_continue
      update_cached_aabb(body, collider)
      handle := DynamicRigidBodyHandle {
        index      = u32(idx),
        generation = entry.generation,
      }
      append(&entries, DynamicBroadPhaseEntry{handle = handle, bounds = body.cached_aabb})
    }
    geometry.bvh_build(&self.dynamic_bvh, entries[:], 4)
    self.killed_body_count = 0 // Reset counter after cleanup
    self.last_dynamic_count = dynamic_body_count // Update tracked count
    bvh_build_time += time.since(bvh_build_start)
  }
  if rebuild_static_bvh {
    bvh_build_start := time.now()
    clear(&self.static_bvh.nodes)
    clear(&self.static_bvh.primitives)
    entries := make(
      [dynamic]StaticBroadPhaseEntry,
      0,
      static_body_count,
      context.temp_allocator,
    )
    for &entry, idx in self.static_bodies.entries do if entry.active {
      body := &entry.item
      if body.collider_handle.generation == 0 do continue
      collider := get(self, body.collider_handle) or_continue
      update_cached_aabb(body, collider)
      handle := StaticRigidBodyHandle {
        index      = u32(idx),
        generation = entry.generation,
      }
      append(&entries, StaticBroadPhaseEntry{handle = handle, bounds = body.cached_aabb})
    }
    geometry.bvh_build(&self.static_bvh, entries[:], 4)
    self.last_static_count = static_body_count // Update tracked count
    bvh_build_time += time.since(bvh_build_start)
  }
  substep_start := time.now()
  dynamic_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    context.temp_allocator,
  )
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    context.temp_allocator,
  )
  refit_time: time.Duration
  broadphase_time: time.Duration
  prepare_time: time.Duration
  solver_time: time.Duration
  integration_time_substep: time.Duration
  #unroll for substep in 0 ..< NUM_SUBSTEPS {
    // clear and redetect contacts at current positions
    refit_start := time.now()
    clear(&self.dynamic_contacts)
    clear(&self.static_contacts)
    // parallel_bvh_refit are slower than sequential_bvh_refit
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
    // Prepare all contacts (compute mass matrices and bias terms)
    prepare_start := time.now()
    for &contact in self.dynamic_contacts {
      body_a := get(self, contact.body_a) or_continue
      body_b := get(self, contact.body_b) or_continue
      prepare_contact(&contact, body_a, body_b, substep_dt)
    }
    for &contact in self.static_contacts {
      body_a := get(self, contact.body_a) or_continue
      body_b := get(self, contact.body_b) or_continue
      prepare_contact(&contact, body_a, body_b, substep_dt)
    }
    prepare_time += time.since(prepare_start)
    // Warmstart with cached impulses (only on first substep)
    solver_start := time.now()
    if substep == 0 {
      for &contact in self.dynamic_contacts {
        body_a := get(self, contact.body_a) or_continue
        body_b := get(self, contact.body_b) or_continue
        warmstart_contact(&contact, body_a, body_b)
      }
      for &contact in self.static_contacts {
        body_a := get(self, contact.body_a) or_continue
        body_b := get(self, contact.body_b) or_continue
        warmstart_contact(&contact, body_a, body_b)
      }
    }
    // Solve constraints with bias (includes position correction + restitution)
    #unroll for _ in 0 ..< CONSTRAINT_SOLVER_ITERS {
      for &contact in self.dynamic_contacts {
        body_a := get(self, contact.body_a) or_continue
        body_b := get(self, contact.body_b) or_continue
        resolve_contact(&contact, body_a, body_b)
      }
      for &contact in self.static_contacts {
        body_a := get(self, contact.body_a) or_continue
        body_b := get(self, contact.body_b) or_continue
        resolve_contact(&contact, body_a, body_b)
      }
    }
    // Additional stabilization iterations WITHOUT bias (pure constraint enforcement)
    #unroll for _ in 0 ..< STABILIZATION_ITERS {
      for &contact in self.dynamic_contacts {
        body_a := get(self, contact.body_a) or_continue
        body_b := get(self, contact.body_b) or_continue
        resolve_contact_no_bias(&contact, body_a, body_b)
      }
      for &contact in self.static_contacts {
        body_a := get(self, contact.body_a) or_continue
        body_b := get(self, contact.body_b) or_continue
        resolve_contact_no_bias(&contact, body_a, body_b)
      }
    }
    solver_time += time.since(solver_start)
    integration_start_substep := time.now()
    for &entry, idx in self.bodies.entries do if entry.active {
      body := &entry.item
      if body.is_killed || body.is_kinematic || body.trigger_only do continue
      if body.is_sleeping do continue
      if idx < len(ccd_handled) && ccd_handled[idx] do continue
      vel := body.velocity * substep_dt
      body.position += vel
      if body.enable_rotation {
        ang_vel_mag_sq := linalg.length2(body.angular_velocity)
        if ang_vel_mag_sq >= math.F32_EPSILON {
          omega_quat := quaternion(w = 0, x = body.angular_velocity.x, y = body.angular_velocity.y, z = body.angular_velocity.z)
          q_old := body.rotation
          q_dot := omega_quat * q_old
          q_dot.w *= 0.5
          q_dot.x *= 0.5
          q_dot.y *= 0.5
          q_dot.z *= 0.5
          q_new := quaternion(w = q_old.w + q_dot.w * substep_dt, x = q_old.x + q_dot.x * substep_dt, y = q_old.y + q_dot.y * substep_dt, z = q_old.z + q_dot.z * substep_dt)
          q_new = linalg.normalize(q_new)
          body.rotation = q_new
        }
      }
    }
    integration_time_substep += time.since(integration_start_substep)
    cache_update_start_substep := time.now()
    if self.enable_parallel {
      parallel_update_aabb_cache(self, self.thread_count)
    } else {
      sequential_update_aabb_cache(self)
    }
    refit_time += time.since(cache_update_start_substep)
  }
  substep_time := time.since(substep_start)
  cache_update_time: time.Duration = 0
  cleanup_start := time.now()
  for &entry, idx in self.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_kinematic || body.is_killed do continue
    if body.position.y < KILL_Y {
      body.is_killed = true
      self.killed_body_count += 1
      when ENABLE_VERBOSE_LOG {
        log.infof("Marking body for removal at y=%.2f (below KILL_Y=%.2f)", body.position.y, KILL_Y)
      }
    }
  }
  cleanup_time := time.since(cleanup_start)
  total_time := time.since(step_start)
  avg_candidates :=
    ccd_bodies_tested > 0 ? f32(ccd_total_candidates) / f32(ccd_bodies_tested) : 0.0
  total_body_count := dynamic_body_count + static_body_count
  log.infof(
    "Physics: %.2fms total | warmstart=%.2fms force=%.2fms integ=%.2fms ccd=%.2fms (fast=%d avg_cands=%.1f) bvh=%.2fms substeps=%.2fms [refit=%.2fms collision=%.2fms prep=%.2fms solve=%.2fms integ=%.2fms] cleanup=%.2fms | bodies=%d (dyn=%d sta=%d) awake=%d contacts=%d (dyn=%d sta=%d)",
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
    time.duration_milliseconds(prepare_time),
    time.duration_milliseconds(solver_time),
    time.duration_milliseconds(integration_time_substep),
    time.duration_milliseconds(cleanup_time),
    total_body_count,
    dynamic_body_count,
    static_body_count,
    awake_body_count,
    len(self.dynamic_contacts) + len(self.static_contacts),
    len(self.dynamic_contacts),
    len(self.static_contacts),
  )
}

get_dynamic_body :: #force_inline proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
) -> (
  ret: ^DynamicRigidBody,
  ok: bool,
) #optional_ok {
  return cont.get(self.bodies, handle)
}

get_static_body :: #force_inline proc(
  self: ^World,
  handle: StaticRigidBodyHandle,
) -> (
  ret: ^StaticRigidBody,
  ok: bool,
) #optional_ok {
  return cont.get(self.static_bodies, handle)
}

get_collider :: #force_inline proc(
  self: ^World,
  handle: ColliderHandle,
) -> (
  ret: ^Collider,
  ok: bool,
) #optional_ok {
  return cont.get(self.colliders, handle)
}

get :: proc {
  get_dynamic_body,
  get_static_body,
  get_collider,
}
