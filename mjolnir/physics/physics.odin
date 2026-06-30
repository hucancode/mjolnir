package physics

import cont "../containers"
import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
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
BVH_REBUILD_THRESHOLD :: #config(PHYSICS_BVH_REBUILD_THRESHOLD, 512) // Rebuild BVH when killed bodies exceed this

DynamicRigidBodyHandle :: distinct cont.Handle
StaticRigidBodyHandle :: distinct cont.Handle
TriggerHandle :: distinct cont.Handle

PerfFrame :: struct {
  total_ms:                 f32,
  warmstart_prep_ms:        f32,
  force_application_ms:     f32,
  ccd_ms:                   f32,
  bvh_build_ms:             f32,
  substep_total_ms:         f32,
  refit_ms:                 f32,
  broadphase_ms:            f32,
  prepare_ms:               f32,
  solver_ms:                f32,
  integration_substep_ms:   f32,
  cleanup_ms:               f32,
  dynamic_body_count:       int,
  static_body_count:        int,
  awake_body_count:         int,
  sleeping_body_count:      int,
  dynamic_contact_count:    int,
  static_contact_count:     int,
  ccd_bodies_tested:        int,
  ccd_total_candidates:     int,
  bvh_dynamic_node_count:   int,
  bvh_static_node_count:    int,
  trigger_overlap_count:    int,
  rebuilt_dynamic_bvh:      bool,
  rebuilt_static_bvh:       bool,
}

TriggerOverlap :: struct {
  trigger: TriggerHandle,
  body:    DynamicRigidBodyHandle,
}

TriggerStaticOverlap :: struct {
  trigger: TriggerHandle,
  body:    StaticRigidBodyHandle,
}

World :: struct {
  bodies:                  cont.Pool(DynamicRigidBody),
  static_bodies:           cont.Pool(StaticRigidBody),
  dynamic_contacts:        [dynamic]DynamicContact,
  static_contacts:         [dynamic]StaticContact,
  prev_dynamic_warmstart:  map[u64]ContactWarmstart,
  prev_static_warmstart:   map[u64]ContactWarmstart,
  trigger_overlaps:        [dynamic]TriggerOverlap,
  trigger_static_overlaps: [dynamic]TriggerStaticOverlap,
  gravity:                 [3]f32,
  gravity_magnitude:       f32,
  dynamic_bvh:             geometry.BVH(DynamicBroadPhaseEntry),
  static_bvh:              geometry.BVH(StaticBroadPhaseEntry),
  body_bounds:             [dynamic]geometry.Aabb,
  trigger_bodies:          cont.Pool(TriggerBody),
  enable_parallel:         bool,
  thread_count:            int,
  thread_pool:             thread.Pool,
  // Deferred body removal tracking
  killed_body_count:       int,
  // BVH rebuild tracking
  last_dynamic_count:      int,
  last_static_count:       int,
  // Solver graph coloring
  solver_color_used:       [dynamic]u64,       // per dynamic body: bitmask of colors used
  solver_color_buckets:    [dynamic][dynamic]int, // per color: contact indices
  solver_color_count:      int,
  solver_static_shards:    [][dynamic]int,    // per shard: static contact indices
  solver_static_shard_count: int,
  // Per-frame performance counters (populated at end of step)
  last_perf:               PerfFrame,
  paused:                  bool,
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
) -> bool {
  self^ = {}
  cont.init(&self.bodies)
  cont.init(&self.static_bodies)
  cont.init(&self.trigger_bodies)
  self.trigger_overlaps = make([dynamic]TriggerOverlap)
  self.trigger_static_overlaps = make([dynamic]TriggerStaticOverlap)
  self.dynamic_contacts = make([dynamic]DynamicContact)
  self.static_contacts = make([dynamic]StaticContact)
  self.prev_dynamic_warmstart = make(map[u64]ContactWarmstart)
  self.prev_static_warmstart = make(map[u64]ContactWarmstart)
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
  self.solver_color_used = make([dynamic]u64)
  self.solver_color_buckets = make([dynamic][dynamic]int)
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
  return true
}

shutdown :: proc(self: ^World) {
  if self.enable_parallel {
    log.infof(
      "Physics.destroy: Destroying thread pool - running=%v, threads=%d",
      self.thread_pool.is_running,
      len(self.thread_pool.threads),
    )
    thread.pool_join(&self.thread_pool)
    thread.pool_destroy(&self.thread_pool)
  }
  cont.destroy(self.bodies, proc(body: ^DynamicRigidBody) {})
  cont.destroy(self.static_bodies, proc(body: ^StaticRigidBody) {})
  cont.destroy(self.trigger_bodies, proc(body: ^TriggerBody) {})
  delete(self.trigger_overlaps)
  delete(self.trigger_static_overlaps)
  delete(self.body_bounds)
  delete(self.dynamic_contacts)
  delete(self.static_contacts)
  delete(self.prev_dynamic_warmstart)
  delete(self.prev_static_warmstart)
  delete(self.solver_color_used)
  for &b in self.solver_color_buckets do delete(b)
  delete(self.solver_color_buckets)
  for &s in self.solver_static_shards do delete(s)
  delete(self.solver_static_shards)
  geometry.bvh_destroy(&self.dynamic_bvh)
  geometry.bvh_destroy(&self.static_bvh)
  self^ = {}
}

teardown :: proc(self: ^World) {
  for i in 0 ..< len(self.bodies.entries) {
    if self.bodies.entries[i].active {
      destroy_dynamic_body(self, DynamicRigidBodyHandle{index = u32(i), generation = self.bodies.entries[i].generation})
    }
  }
  for i in 0 ..< len(self.static_bodies.entries) {
    if self.static_bodies.entries[i].active {
      destroy_static_body(self, StaticRigidBodyHandle{index = u32(i), generation = self.static_bodies.entries[i].generation})
    }
  }
  for i in 0 ..< len(self.trigger_bodies.entries) {
    if self.trigger_bodies.entries[i].active {
      destroy_trigger(self, TriggerHandle{index = u32(i), generation = self.trigger_bodies.entries[i].generation})
    }
  }
  clear(&self.dynamic_contacts)
  clear(&self.static_contacts)
  clear(&self.prev_dynamic_warmstart)
  clear(&self.prev_static_warmstart)
  clear(&self.trigger_overlaps)
  clear(&self.trigger_static_overlaps)
  clear(&self.dynamic_bvh.primitives)
  clear(&self.dynamic_bvh.nodes)
  clear(&self.static_bvh.primitives)
  clear(&self.static_bvh.nodes)
  self.last_dynamic_count = 0
  self.last_static_count = 0
  self.killed_body_count = 0
}

create_dynamic_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  collider: Collider = {},
) -> (
  handle: DynamicRigidBodyHandle,
  ok: bool,
) #optional_ok {
  body: ^DynamicRigidBody
  handle, body = cont.alloc(&self.bodies, DynamicRigidBodyHandle) or_return
  rigid_body_init(body, position, rotation, mass)
  body.collider = collider
  return handle, true
}

create_static_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  collider: Collider = {},
) -> (
  handle: StaticRigidBodyHandle,
  ok: bool,
) #optional_ok {
  body: ^StaticRigidBody
  handle, body = cont.alloc(
    &self.static_bodies,
    StaticRigidBodyHandle,
  ) or_return
  static_rigid_body_init(body, position, rotation)
  body.collider = collider
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

trigger_collides :: #force_inline proc(trigger: ^TriggerBody, body: ^RigidBody) -> bool {
  _, _, _, hit := test_collision(
    &trigger.collider, trigger.position, trigger.rotation,
    &body.collider, body.position, body.rotation,
  )
  return hit
}

@(private)
step_warmstart_prep :: proc(self: ^World) {
  clear(&self.prev_dynamic_warmstart)
  clear(&self.prev_static_warmstart)
  for contact in self.dynamic_contacts {
    if contact.normal_impulse == 0 && contact.tangent_impulse == {0, 0} do continue
    self.prev_dynamic_warmstart[collision_pair_hash(contact.body_a, contact.body_b)] = ContactWarmstart {
      normal  = contact.normal_impulse,
      tangent = contact.tangent_impulse,
    }
  }
  for contact in self.static_contacts {
    if contact.normal_impulse == 0 && contact.tangent_impulse == {0, 0} do continue
    self.prev_static_warmstart[collision_pair_hash(contact.body_a, contact.body_b)] = ContactWarmstart {
      normal  = contact.normal_impulse,
      tangent = contact.tangent_impulse,
    }
  }
}

@(private)
step_apply_forces_and_sleep :: proc(self: ^World, dt: f32) -> (awake_count, dynamic_count: int) {
  for i in 0 ..< len(self.bodies.entries) {
    if !self.bodies.entries[i].active do continue
    body := &self.bodies.entries[i].item
    if body.is_killed do continue
    dynamic_count += 1
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
    if body.is_sleeping do continue
    awake_count += 1
    body.velocity += (self.gravity + body.force * body.inv_mass) * dt
    body.velocity *= math.pow(1.0 - body.linear_damping, dt)
    body.force = {}
    body.torque = {}
  }
  return
}

@(private)
step_rebuild_dynamic_bvh :: proc(self: ^World, dynamic_body_count: int) {
  clear(&self.dynamic_bvh.nodes)
  clear(&self.dynamic_bvh.primitives)
  entries := make([dynamic]DynamicBroadPhaseEntry, 0, dynamic_body_count, context.temp_allocator)
  for idx in 0 ..< len(self.bodies.entries) {
    if !self.bodies.entries[idx].active do continue
    body := &self.bodies.entries[idx].item
    handle := DynamicRigidBodyHandle{index = u32(idx), generation = self.bodies.entries[idx].generation}
    if body.is_killed {
      destroy_body(self, handle)
      continue
    }
    update_cached_aabb(&body.base)
    append(&entries, DynamicBroadPhaseEntry{handle = handle, bounds = body.cached_aabb})
  }
  if self.enable_parallel {
    geometry.bvh_build_parallel(&self.dynamic_bvh, entries[:], &self.thread_pool, 4, 1000)
  } else {
    geometry.bvh_build(&self.dynamic_bvh, entries[:], 4)
  }
  self.killed_body_count = 0
  self.last_dynamic_count = dynamic_body_count
}

@(private)
step_rebuild_static_bvh :: proc(self: ^World, static_body_count: int) {
  clear(&self.static_bvh.nodes)
  clear(&self.static_bvh.primitives)
  entries := make([dynamic]StaticBroadPhaseEntry, 0, static_body_count, context.temp_allocator)
  for idx in 0 ..< len(self.static_bodies.entries) {
    if !self.static_bodies.entries[idx].active do continue
    body := &self.static_bodies.entries[idx].item
    update_cached_aabb(&body.base)
    handle := StaticRigidBodyHandle{index = u32(idx), generation = self.static_bodies.entries[idx].generation}
    append(&entries, StaticBroadPhaseEntry{handle = handle, bounds = body.cached_aabb})
  }
  if self.enable_parallel {
    geometry.bvh_build_parallel(&self.static_bvh, entries[:], &self.thread_pool, 4, 1000)
  } else {
    geometry.bvh_build(&self.static_bvh, entries[:], 4)
  }
  self.last_static_count = static_body_count
}

@(private)
SubstepTimes :: struct {
  refit, broadphase, prepare, solver, integration: time.Duration,
}

@(private)
step_substep :: proc(self: ^World, substep_dt: f32, ccd_handled: []bool, is_first: bool) -> SubstepTimes {
  times: SubstepTimes
  refit_start := time.now()
  clear(&self.dynamic_contacts)
  clear(&self.static_contacts)
  if self.enable_parallel {
    parallel_bvh_refit(self, self.thread_count)
  } else {
    sequential_bvh_refit(self)
  }
  times.refit = time.since(refit_start)

  broadphase_start := time.now()
  if self.enable_parallel {
    parallel_collision_detection_traversal(self, self.thread_count)
  } else {
    sequential_collision_detection_traversal(self)
  }
  times.broadphase = time.since(broadphase_start)

  prepare_start := time.now()
  if self.enable_parallel {
    parallel_prepare_contacts(self, substep_dt, self.thread_count)
  } else {
    sequential_prepare_contacts(self, substep_dt)
  }
  times.prepare = time.since(prepare_start)

  solver_start := time.now()
  if is_first {
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
  clear_pseudo_velocities(self)
  if self.enable_parallel {
    build_solver_partition(self, self.thread_count)
    run_solver_iters(self, CONSTRAINT_SOLVER_ITERS, STABILIZATION_ITERS, self.thread_count)
  } else {
    for _ in 0 ..< CONSTRAINT_SOLVER_ITERS {
      solve_velocity_pass(self)
    }
    for _ in 0 ..< STABILIZATION_ITERS {
      solve_position_pass(self)
    }
  }
  times.solver = time.since(solver_start)

  integration_start := time.now()
  integrate_positions(self, substep_dt, ccd_handled)
  times.integration = time.since(integration_start)
  return times
}

@(private)
step_triggers :: proc(self: ^World) {
  clear(&self.trigger_overlaps)
  clear(&self.trigger_static_overlaps)
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, context.temp_allocator)
  static_candidates := make([dynamic]StaticBroadPhaseEntry, context.temp_allocator)
  for i in 0 ..< len(self.trigger_bodies.entries) {
    if !self.trigger_bodies.entries[i].active do continue
    trigger := &self.trigger_bodies.entries[i].item
    trigger_handle := TriggerHandle{index = u32(i), generation = self.trigger_bodies.entries[i].generation}
    update_cached_aabb(&trigger.base)
    clear(&dyn_candidates)
    geometry.bvh_query_aabb(&self.dynamic_bvh, trigger.cached_aabb, &dyn_candidates)
    for candidate in dyn_candidates {
      body := get(self, candidate.handle) or_continue
      if body.is_killed do continue
      if !trigger_collides(trigger, &body.base) do continue
      append(&self.trigger_overlaps, TriggerOverlap{trigger = trigger_handle, body = candidate.handle})
    }
    clear(&static_candidates)
    geometry.bvh_query_aabb(&self.static_bvh, trigger.cached_aabb, &static_candidates)
    for candidate in static_candidates {
      body := get(self, candidate.handle) or_continue
      if !trigger_collides(trigger, &body.base) do continue
      append(&self.trigger_static_overlaps, TriggerStaticOverlap{trigger = trigger_handle, body = candidate.handle})
    }
  }
}

@(private)
step_cleanup_and_count :: proc(self: ^World) -> (sleeping_count: int) {
  for i in 0 ..< len(self.bodies.entries) {
    if !self.bodies.entries[i].active do continue
    body := &self.bodies.entries[i].item
    if body.is_killed do continue
    if body.position.y < KILL_Y {
      body.is_killed = true
      self.killed_body_count += 1
      continue
    }
    if body.is_sleeping do sleeping_count += 1
  }
  return
}

step :: proc(self: ^World, dt: f32) {
  if self.paused do return
  step_start := time.now()

  warmstart_start := time.now()
  step_warmstart_prep(self)
  warmstart_prep_time := time.since(warmstart_start)

  force_start := time.now()
  awake_body_count, dynamic_body_count := step_apply_forces_and_sleep(self, dt)
  force_application_time := time.since(force_start)

  ccd_handled := make([dynamic]bool, len(self.bodies.entries), context.temp_allocator)
  ccd_start := time.now()
  ccd_bodies_tested, ccd_total_candidates: int
  if self.enable_parallel {
    ccd_bodies_tested, ccd_total_candidates = parallel_ccd(self, dt, ccd_handled[:], self.thread_count)
  } else {
    ccd_bodies_tested, ccd_total_candidates = sequential_ccd(self, dt, ccd_handled[:])
  }
  ccd_time := time.since(ccd_start)

  static_body_count := 0
  for i in 0 ..< len(self.static_bodies.entries) {
    if self.static_bodies.entries[i].active do static_body_count += 1
  }

  rebuild_dynamic_bvh := dynamic_body_count > self.last_dynamic_count || self.killed_body_count >= BVH_REBUILD_THRESHOLD
  rebuild_static_bvh := static_body_count > self.last_static_count
  bvh_build_time: time.Duration
  if rebuild_dynamic_bvh {
    t := time.now()
    step_rebuild_dynamic_bvh(self, dynamic_body_count)
    bvh_build_time += time.since(t)
  }
  if rebuild_static_bvh {
    t := time.now()
    step_rebuild_static_bvh(self, static_body_count)
    bvh_build_time += time.since(t)
  }

  substep_dt := dt / f32(NUM_SUBSTEPS)
  substep_start := time.now()
  totals: SubstepTimes
  for substep in 0 ..< NUM_SUBSTEPS {
    times := step_substep(self, substep_dt, ccd_handled[:], substep == 0)
    totals.refit += times.refit
    totals.broadphase += times.broadphase
    totals.prepare += times.prepare
    totals.solver += times.solver
    totals.integration += times.integration
  }
  substep_time := time.since(substep_start)

  step_triggers(self)

  cleanup_start := time.now()
  sleeping_body_count := step_cleanup_and_count(self)
  cleanup_time := time.since(cleanup_start)

  total_time := time.since(step_start)
  self.last_perf = PerfFrame {
    total_ms               = f32(time.duration_milliseconds(total_time)),
    warmstart_prep_ms      = f32(time.duration_milliseconds(warmstart_prep_time)),
    force_application_ms   = f32(time.duration_milliseconds(force_application_time)),
    ccd_ms                 = f32(time.duration_milliseconds(ccd_time)),
    bvh_build_ms           = f32(time.duration_milliseconds(bvh_build_time)),
    substep_total_ms       = f32(time.duration_milliseconds(substep_time)),
    refit_ms               = f32(time.duration_milliseconds(totals.refit)),
    broadphase_ms          = f32(time.duration_milliseconds(totals.broadphase)),
    prepare_ms             = f32(time.duration_milliseconds(totals.prepare)),
    solver_ms              = f32(time.duration_milliseconds(totals.solver)),
    integration_substep_ms = f32(time.duration_milliseconds(totals.integration)),
    cleanup_ms             = f32(time.duration_milliseconds(cleanup_time)),
    dynamic_body_count     = dynamic_body_count,
    static_body_count      = static_body_count,
    awake_body_count       = awake_body_count,
    sleeping_body_count    = sleeping_body_count,
    dynamic_contact_count  = len(self.dynamic_contacts),
    static_contact_count   = len(self.static_contacts),
    ccd_bodies_tested      = ccd_bodies_tested,
    ccd_total_candidates   = ccd_total_candidates,
    bvh_dynamic_node_count = len(self.dynamic_bvh.nodes),
    bvh_static_node_count  = len(self.static_bvh.nodes),
    trigger_overlap_count  = len(self.trigger_overlaps) + len(self.trigger_static_overlaps),
    rebuilt_dynamic_bvh    = rebuild_dynamic_bvh,
    rebuilt_static_bvh     = rebuild_static_bvh,
  }
  when ENABLE_VERBOSE_LOG {
    log.infof(
      "Physics: %.2fms total | warmstart=%.2fms force=%.2fms ccd=%.2fms bvh=%.2fms substeps=%.2fms [refit=%.2fms collision=%.2fms prep=%.2fms solve=%.2fms integ=%.2fms] cleanup=%.2fms | bodies dyn=%d sta=%d awake=%d contacts dyn=%d sta=%d",
      time.duration_milliseconds(total_time),
      time.duration_milliseconds(warmstart_prep_time),
      time.duration_milliseconds(force_application_time),
      time.duration_milliseconds(ccd_time),
      time.duration_milliseconds(bvh_build_time),
      time.duration_milliseconds(substep_time),
      time.duration_milliseconds(totals.refit),
      time.duration_milliseconds(totals.broadphase),
      time.duration_milliseconds(totals.prepare),
      time.duration_milliseconds(totals.solver),
      time.duration_milliseconds(totals.integration),
      time.duration_milliseconds(cleanup_time),
      dynamic_body_count, static_body_count, awake_body_count,
      len(self.dynamic_contacts), len(self.static_contacts),
    )
  }
}

rebuild_dynamic_bvh :: proc(self: ^World) {
  count := 0
  for i in 0 ..< len(self.bodies.entries) {
    if self.bodies.entries[i].active && !self.bodies.entries[i].item.is_killed {
      count += 1
    }
  }
  step_rebuild_dynamic_bvh(self, count)
}

rebuild_static_bvh :: proc(self: ^World) {
  count := 0
  for i in 0 ..< len(self.static_bodies.entries) {
    if self.static_bodies.entries[i].active do count += 1
  }
  step_rebuild_static_bvh(self, count)
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

get_trigger :: #force_inline proc(
  self: ^World,
  handle: TriggerHandle,
) -> (
  ret: ^TriggerBody,
  ok: bool,
) #optional_ok {
  return cont.get(self.trigger_bodies, handle)
}

get :: proc {
  get_dynamic_body,
  get_static_body,
  get_trigger,
}

create_trigger :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  collider: Collider = {},
) -> (
  handle: TriggerHandle,
  ok: bool,
) #optional_ok {
  body: ^TriggerBody
  handle, body = cont.alloc(&self.trigger_bodies, TriggerHandle) or_return
  body.position = position
  body.rotation = rotation
  body.collider = collider
  update_cached_aabb(&body.base)
  return handle, true
}

destroy_trigger :: proc(self: ^World, handle: TriggerHandle) {
  cont.free(&self.trigger_bodies, handle)
}

set_trigger_position :: proc(
  self: ^World,
  handle: TriggerHandle,
  position: [3]f32,
) {
  body, ok := get_trigger(self, handle)
  if !ok do return
  body.position = position
  update_cached_aabb(&body.base)
}

set_trigger_rotation :: proc(
  self: ^World,
  handle: TriggerHandle,
  rotation: quaternion128,
) {
  body, ok := get_trigger(self, handle)
  if !ok do return
  body.rotation = rotation
  update_cached_aabb(&body.base)
}

set_trigger_transform :: proc(
  self: ^World,
  handle: TriggerHandle,
  position: [3]f32,
  rotation: quaternion128,
) {
  body, ok := get_trigger(self, handle)
  if !ok do return
  body.position = position
  body.rotation = rotation
  update_cached_aabb(&body.base)
}
