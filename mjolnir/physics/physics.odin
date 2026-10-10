package physics

import cont "../containers"
import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:thread"
import "core:time"

KILL_Y :: #config(PHYSICS_KILL_Y, -50.0)
SEA_LEVEL_AIR_DENSITY :: 1.225
NUM_SUBSTEPS :: 4
SLEEP_LINEAR_THRESHOLD :: 0.05
SLEEP_ANGULAR_THRESHOLD :: 0.05
SLEEP_LINEAR_THRESHOLD_SQ :: SLEEP_LINEAR_THRESHOLD * SLEEP_LINEAR_THRESHOLD
SLEEP_ANGULAR_THRESHOLD_SQ :: SLEEP_ANGULAR_THRESHOLD * SLEEP_ANGULAR_THRESHOLD
SLEEP_TIME_THRESHOLD :: 0.5
ENABLE_VERBOSE_LOG :: #config(PHYSICS_VERBOSE_LOG, false)
// Millisecond timings in PerfFrame cost a dozen clock reads per step; compile
// them out with -define:PHYSICS_PERF_STATS=false. Counters are always filled.
PHYSICS_PERF_STATS :: #config(PHYSICS_PERF_STATS, true)
MAX_LINEAR_SPEED :: #config(PHYSICS_MAX_LINEAR_SPEED, 400.0)
MAX_ROTATION_PER_STEP :: 0.25 * math.PI
BVH_REBUILD_THRESHOLD :: #config(PHYSICS_BVH_REBUILD_THRESHOLD, 512) // Rebuild BVH when killed bodies exceed this
// Contacts are created while shapes are still this far apart:
// the solver's speculative branch stops approach exactly at touch, preventing
// tunneling at moderate speeds without CCD.
SPECULATIVE_DISTANCE :: 0.02

DynamicRigidBodyHandle :: distinct cont.Handle
StaticRigidBodyHandle :: distinct cont.Handle
TriggerHandle :: distinct cont.Handle

PerfFrame :: struct {
  total_ms:                 f32,
  warmstart_prep_ms:        f32,
  ccd_ms:                   f32,
  bvh_build_ms:             f32,
  substep_total_ms:         f32,
  refit_ms:                 f32,
  broadphase_ms:            f32,
  prepare_ms:               f32,
  finalize_ms:              f32,
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

// One solver point of a contact manifold
// base_separation: signed separation at prepare time (negative = penetrating);
// current separation is recovered per substep from body position deltas.
// relative_velocity: normal approach speed captured at prepare, used by the
// post-substep restitution pass.
ContactPoint :: struct {
  point:              [3]f32,
  penetration:        f32, // filled by narrowphase; prepare converts to base_separation
  feature_id:         u32,
  normal_impulse:     f32,
  max_normal_impulse: f32,
  normal_mass:        f32,
  base_separation:    f32,
  relative_velocity:  f32,
  r_a:                [3]f32,
  r_b:                [3]f32,
}

// Contact between two dynamic bodies: up to 4 normal points plus one
// manifold-level friction constraint (coupled 2D tangent at the centroid +
// twist about the normal).
DynamicContact :: struct {
  body_a:          DynamicRigidBodyHandle,
  body_b:          DynamicRigidBodyHandle,
  normal:          [3]f32,
  restitution:     f32,
  friction:        f32,
  count:           int,
  points:          [MAX_MANIFOLD_POINTS]ContactPoint,
  tangent1:        [3]f32,
  tangent2:        [3]f32,
  r_a_c:           [3]f32, // centroid offset from body A center
  r_b_c:           [3]f32,
  tangent_impulse: [2]f32,
  twist_impulse:   f32,
  tangent_mass:    matrix[2, 2]f32, // inverse of the coupled tangent K matrix
  twist_mass:      f32,
}

// Contact between dynamic body (A) and static body (B)
StaticContact :: struct {
  body_a:          DynamicRigidBodyHandle,
  body_b:          StaticRigidBodyHandle,
  normal:          [3]f32,
  restitution:     f32,
  friction:        f32,
  count:           int,
  points:          [MAX_MANIFOLD_POINTS]ContactPoint,
  tangent1:        [3]f32,
  tangent2:        [3]f32,
  r_a_c:           [3]f32,
  tangent_impulse: [2]f32,
  twist_impulse:   f32,
  tangent_mass:    matrix[2, 2]f32,
  twist_mass:      f32,
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
  dynamic_bvh:             geometry.BVH(DynamicBroadPhaseEntry),
  static_bvh:              geometry.BVH(StaticBroadPhaseEntry),
  trigger_bodies:          cont.Pool(TriggerBody),
  enable_parallel:         bool,
  thread_count:            int,
  thread_pool:             thread.Pool,
  // Deferred body removal tracking
  killed_body_count:       int,
  // Set when bodies are created; the next step rebuilds that BVH
  dynamic_bvh_dirty:       bool,
  static_bvh_dirty:        bool,
  // Dense list of awake body indices, rebuilt after narrowphase each frame
  // (narrowphase can wake sleeping bodies). Hot substep loops iterate this
  // instead of branching over the whole pool.
  awake_list:              [dynamic]u32,
  // Solver graph coloring
  solver_color_used:       [dynamic]u64,       // per dynamic body: bitmask of colors used
  solver_color_buckets:    [dynamic][dynamic]int, // per color: contact indices
  solver_overflow:         [dynamic]int, // contacts that fit no color; solved single-threaded
  solver_color_count:      int,
  solver_static_shards:    [][dynamic]int,    // per shard: static contact indices
  solver_static_shard_count: int,
  // Per-frame performance counters (populated at end of step)
  last_perf:               PerfFrame,
  paused:                  bool,
}

@(private)
DynamicBroadPhaseEntry :: struct {
  handle: DynamicRigidBodyHandle,
  bounds: geometry.Aabb,
}

@(private)
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
  self.solver_color_used = make([dynamic]u64)
  self.solver_color_buckets = make([dynamic][dynamic]int)
  self.solver_overflow = make([dynamic]int)
  self.awake_list = make([dynamic]u32)
  self.enable_parallel = enable_parallel
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
  cont.destroy(&self.bodies, proc(body: ^DynamicRigidBody) {})
  cont.destroy(&self.static_bodies, proc(body: ^StaticRigidBody) {})
  cont.destroy(&self.trigger_bodies, proc(body: ^TriggerBody) {})
  delete(self.trigger_overlaps)
  delete(self.trigger_static_overlaps)
  delete(self.dynamic_contacts)
  delete(self.static_contacts)
  delete(self.prev_dynamic_warmstart)
  delete(self.prev_static_warmstart)
  delete(self.solver_color_used)
  for &b in self.solver_color_buckets do delete(b)
  delete(self.solver_color_buckets)
  delete(self.solver_overflow)
  delete(self.awake_list)
  for &s in self.solver_static_shards do delete(s)
  delete(self.solver_static_shards)
  geometry.bvh_destroy(&self.dynamic_bvh)
  geometry.bvh_destroy(&self.static_bvh)
  self^ = {}
}

teardown :: proc(self: ^World) {
  dyn_it := cont.iterator(&self.bodies)
  for _, handle in cont.next(&dyn_it, DynamicRigidBodyHandle) do destroy_dynamic_body(self, handle)
  static_it := cont.iterator(&self.static_bodies)
  for _, handle in cont.next(&static_it, StaticRigidBodyHandle) do destroy_static_body(self, handle)
  trigger_it := cont.iterator(&self.trigger_bodies)
  for _, handle in cont.next(&trigger_it, TriggerHandle) do destroy_trigger(self, handle)
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
  self.dynamic_bvh_dirty = false
  self.static_bvh_dirty = false
  self.killed_body_count = 0
}

create_dynamic_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  mass: f32 = 1.0,
  collider: Collider = {},
  user: cont.Handle = {},
) -> (
  handle: DynamicRigidBodyHandle,
  ok: bool,
) #optional_ok {
  body: ^DynamicRigidBody
  handle, body = cont.alloc(&self.bodies, DynamicRigidBodyHandle) or_return
  rigid_body_init(body, position, rotation, mass)
  body.collider = collider
  set_inertia_from_collider(body, collider)
  body.user = user
  self.dynamic_bvh_dirty = true
  return handle, true
}

create_static_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  collider: Collider = {},
  user: cont.Handle = {},
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
  body.user = user
  self.static_bvh_dirty = true
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

@(private)
trigger_collides :: #force_inline proc(trigger: ^TriggerBody, body: ^RigidBody) -> bool {
  _, hit := collide(
    &trigger.collider, trigger.position, trigger.rotation,
    &body.collider, body.position, body.rotation,
  )
  return hit
}

@(private)
step_warmstart_prep :: proc(self: ^World) {
  clear(&self.prev_dynamic_warmstart)
  clear(&self.prev_static_warmstart)
  for &contact in self.dynamic_contacts {
    if !contact_has_impulse(&contact) do continue
    self.prev_dynamic_warmstart[collision_pair_hash(contact.body_a, contact.body_b)] =
      contact_store_warmstart(&contact)
  }
  for &contact in self.static_contacts {
    if !contact_has_impulse(&contact) do continue
    self.prev_static_warmstart[collision_pair_hash(contact.body_a, contact.body_b)] =
      contact_store_warmstart(&contact)
  }
}

@(private)
step_count_dynamic :: proc(self: ^World) -> (dynamic_count: int) {
  it := cont.iterator(&self.bodies)
  for body in cont.next(&it, DynamicRigidBodyHandle) {
    if !body.is_killed do dynamic_count += 1
  }
  return
}

// Island-based sleeping (end of frame, post-solve velocities): bodies linked
// by dynamic contacts sleep only when EVERY island member has been quiet for
// SLEEP_TIME_THRESHOLD. Per-body sleep leaves boxes floating when their
// support dozes off first; per-island can't. Also marks fallen bodies
// (KILL_Y) for deferred removal in the same sweep.
@(private)
step_island_sleep :: proc(self: ^World, dt: f32) -> (awake_count, sleeping_count: int) {
  n := len(self.bodies.entries)
  if n == 0 do return
  parent := make([]i32, n, context.temp_allocator)
  for i in 0 ..< n do parent[i] = i32(i)
  find :: proc(parent: []i32, x: i32) -> i32 {
    root := x
    for parent[root] != root do root = parent[root]
    // path compression
    cur := x
    for parent[cur] != root {
      next := parent[cur]
      parent[cur] = root
      cur = next
    }
    return root
  }
  for &c in self.dynamic_contacts {
    a := int(c.body_a.index)
    b := int(c.body_b.index)
    if a >= n || b >= n do continue
    ra := find(parent, i32(a))
    rb := find(parent, i32(b))
    if ra != rb do parent[rb] = ra
  }
  // Per-body quiet timers
  it := cont.iterator(&self.bodies)
  for body in cont.next(&it, DynamicRigidBodyHandle) {
    if body.is_killed do continue
    lin_speed_sq := linalg.length2(body.velocity)
    ang_speed_sq := linalg.length2(body.angular_velocity)
    if lin_speed_sq < SLEEP_LINEAR_THRESHOLD_SQ && ang_speed_sq < SLEEP_ANGULAR_THRESHOLD_SQ {
      body.sleep_timer += dt
    } else {
      body.sleep_timer = 0
      body.is_sleeping = false
    }
  }
  // Island-minimum quiet time
  island_min := make([]f32, n, context.temp_allocator)
  for i in 0 ..< n do island_min[i] = math.F32_MAX
  it = cont.iterator(&self.bodies)
  for body, handle in cont.next(&it, DynamicRigidBodyHandle) {
    if body.is_killed do continue
    root := find(parent, i32(handle.index))
    island_min[root] = min(island_min[root], body.sleep_timer)
  }
  it = cont.iterator(&self.bodies)
  for body, handle in cont.next(&it, DynamicRigidBodyHandle) {
    if body.is_killed do continue
    if body.position.y < KILL_Y {
      body.is_killed = true
      self.killed_body_count += 1
      continue
    }
    root := find(parent, i32(handle.index))
    if island_min[root] > SLEEP_TIME_THRESHOLD {
      body.is_sleeping = true
      body.velocity = {}
      body.angular_velocity = {}
      sleeping_count += 1
    } else {
      awake_count += 1
    }
  }
  return
}

@(private)
step_rebuild_dynamic_bvh :: proc(self: ^World, dynamic_body_count: int) {
  clear(&self.dynamic_bvh.nodes)
  clear(&self.dynamic_bvh.primitives)
  entries := make([dynamic]DynamicBroadPhaseEntry, 0, dynamic_body_count, context.temp_allocator)
  it := cont.iterator(&self.bodies)
  for body, handle in cont.next(&it, DynamicRigidBodyHandle) {
    if body.is_killed {
      destroy_body(self, handle)
      continue
    }
    update_cached_aabb(&body.base)
    fat := geometry.Aabb {
      min = body.cached_aabb.min - SPECULATIVE_DISTANCE,
      max = body.cached_aabb.max + SPECULATIVE_DISTANCE,
    }
    append(&entries, DynamicBroadPhaseEntry{handle = handle, bounds = fat})
  }
  if self.enable_parallel {
    geometry.bvh_build_parallel(&self.dynamic_bvh, entries[:], &self.thread_pool, 4, 1000)
  } else {
    geometry.bvh_build(&self.dynamic_bvh, entries[:], 4)
  }
  self.killed_body_count = 0
  self.dynamic_bvh_dirty = false
}

@(private)
step_rebuild_static_bvh :: proc(self: ^World, static_body_count: int) {
  clear(&self.static_bvh.nodes)
  clear(&self.static_bvh.primitives)
  entries := make([dynamic]StaticBroadPhaseEntry, 0, static_body_count, context.temp_allocator)
  it := cont.iterator(&self.static_bodies)
  for body, handle in cont.next(&it, StaticRigidBodyHandle) {
    update_cached_aabb(&body.base)
    append(&entries, StaticBroadPhaseEntry{handle = handle, bounds = body.cached_aabb})
  }
  if self.enable_parallel {
    geometry.bvh_build_parallel(&self.static_bvh, entries[:], &self.thread_pool, 4, 1000)
  } else {
    geometry.bvh_build(&self.static_bvh, entries[:], 4)
  }
  self.static_bvh_dirty = false
}

@(private)
step_triggers :: proc(self: ^World) {
  clear(&self.trigger_overlaps)
  clear(&self.trigger_static_overlaps)
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, context.temp_allocator)
  static_candidates := make([dynamic]StaticBroadPhaseEntry, context.temp_allocator)
  it := cont.iterator(&self.trigger_bodies)
  for trigger, trigger_handle in cont.next(&it, TriggerHandle) {
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

// Millisecond timing blocks compile out with PHYSICS_PERF_STATS=false;
// the durations then stay zero.
step :: proc(self: ^World, dt: f32) {
  if self.paused do return
  warmstart_prep_time, ccd_time, bvh_build_time: time.Duration
  refit_time, broadphase_time, prepare_time, substep_time, finalize_time: time.Duration
  cleanup_time, total_time: time.Duration
  when PHYSICS_PERF_STATS {
    step_start := time.now()
    mark := step_start
  }

  step_warmstart_prep(self)
  when PHYSICS_PERF_STATS {
    warmstart_prep_time = time.since(mark)
  }

  dynamic_body_count := step_count_dynamic(self)

  ccd_handled := make([dynamic]bool, len(self.bodies.entries), context.temp_allocator)
  when PHYSICS_PERF_STATS do mark = time.now()
  ccd_bodies_tested, ccd_total_candidates: int
  if self.enable_parallel {
    ccd_bodies_tested, ccd_total_candidates = parallel_ccd(self, dt, ccd_handled[:], self.thread_count)
  } else {
    ccd_bodies_tested, ccd_total_candidates = sequential_ccd(self, dt, ccd_handled[:])
  }
  when PHYSICS_PERF_STATS do ccd_time = time.since(mark)

  static_body_count := cont.count(self.static_bodies)

  rebuild_dynamic_bvh := self.dynamic_bvh_dirty || self.killed_body_count >= BVH_REBUILD_THRESHOLD
  rebuild_static_bvh := self.static_bvh_dirty
  if rebuild_dynamic_bvh || rebuild_static_bvh {
    when PHYSICS_PERF_STATS do mark = time.now()
    if rebuild_dynamic_bvh do step_rebuild_dynamic_bvh(self, dynamic_body_count)
    if rebuild_static_bvh do step_rebuild_static_bvh(self, static_body_count)
    when PHYSICS_PERF_STATS do bvh_build_time = time.since(mark)
  }

  // Anchor frame-start positions for per-substep separation recovery, and
  // check the all-asleep fast path (nothing can move → skip the pipeline)
  any_awake := false
  it := cont.iterator(&self.bodies)
  for body in cont.next(&it, DynamicRigidBodyHandle) {
    body.position0 = body.position
    if !body.is_killed && !body.is_sleeping do any_awake = true
  }

  substep_dt := dt / f32(NUM_SUBSTEPS)
  if any_awake {
    when PHYSICS_PERF_STATS do mark = time.now()
    clear(&self.dynamic_contacts)
    clear(&self.static_contacts)
    if self.enable_parallel {
      parallel_bvh_refit(self, self.thread_count)
    } else {
      sequential_bvh_refit(self)
    }
    when PHYSICS_PERF_STATS {
      refit_time = time.since(mark)
      mark = time.now()
    }

    if self.enable_parallel {
      parallel_collision_detection_traversal(self, self.thread_count)
    } else {
      sequential_collision_detection_traversal(self)
    }
    when PHYSICS_PERF_STATS do broadphase_time = time.since(mark)

    // Narrowphase may have woken sleeping bodies — build the dense awake
    // list only now
    clear(&self.awake_list)
    awake_it := cont.iterator(&self.bodies)
    for body, handle in cont.next(&awake_it, DynamicRigidBodyHandle) {
      if body.is_killed || body.is_sleeping do continue
      append(&self.awake_list, handle.index)
    }

    when PHYSICS_PERF_STATS do mark = time.now()
    if self.enable_parallel {
      parallel_prepare_contacts(self, substep_dt, self.thread_count)
    } else {
      sequential_prepare_contacts(self, substep_dt)
    }
    when PHYSICS_PERF_STATS {
      prepare_time = time.since(mark)
      mark = time.now()
    }

    run_substep_loop(self, substep_dt, NUM_SUBSTEPS, ccd_handled[:], self.thread_count)
    when PHYSICS_PERF_STATS {
      substep_time = time.since(mark)
      mark = time.now()
    }

    // Finalize: refresh spatial caches once per frame
    for li in 0 ..< len(self.awake_list) {
      body := &self.bodies.entries[self.awake_list[li]].item
      body.force = {}
      body.torque = {}
      update_cached_aabb(&body.base)
    }
    when PHYSICS_PERF_STATS do finalize_time = time.since(mark)
  }

  step_triggers(self)

  when PHYSICS_PERF_STATS do mark = time.now()
  awake_body_count, sleeping_body_count := step_island_sleep(self, dt)
  when PHYSICS_PERF_STATS {
    cleanup_time = time.since(mark)
    total_time = time.since(step_start)
  }

  self.last_perf = PerfFrame {
    total_ms               = f32(time.duration_milliseconds(total_time)),
    warmstart_prep_ms      = f32(time.duration_milliseconds(warmstart_prep_time)),
    ccd_ms                 = f32(time.duration_milliseconds(ccd_time)),
    bvh_build_ms           = f32(time.duration_milliseconds(bvh_build_time)),
    substep_total_ms       = f32(time.duration_milliseconds(substep_time)),
    refit_ms               = f32(time.duration_milliseconds(refit_time)),
    broadphase_ms          = f32(time.duration_milliseconds(broadphase_time)),
    prepare_ms             = f32(time.duration_milliseconds(prepare_time)),
    finalize_ms            = f32(time.duration_milliseconds(finalize_time)),
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
      "Physics: %.2fms total | warmstart=%.2fms ccd=%.2fms bvh=%.2fms [refit=%.2fms collision=%.2fms prep=%.2fms solve=%.2fms finalize=%.2fms] cleanup=%.2fms | bodies dyn=%d sta=%d awake=%d contacts dyn=%d sta=%d",
      time.duration_milliseconds(total_time),
      time.duration_milliseconds(warmstart_prep_time),
      time.duration_milliseconds(ccd_time),
      time.duration_milliseconds(bvh_build_time),
      time.duration_milliseconds(refit_time),
      time.duration_milliseconds(broadphase_time),
      time.duration_milliseconds(prepare_time),
      time.duration_milliseconds(substep_time),
      time.duration_milliseconds(finalize_time),
      time.duration_milliseconds(cleanup_time),
      dynamic_body_count, static_body_count, awake_body_count,
      len(self.dynamic_contacts), len(self.static_contacts),
    )
  }
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
  user: cont.Handle = {},
) -> (
  handle: TriggerHandle,
  ok: bool,
) #optional_ok {
  body: ^TriggerBody
  handle, body = cont.alloc(&self.trigger_bodies, TriggerHandle) or_return
  body.position = position
  body.rotation = rotation
  body.collider = collider
  body.user = user
  update_cached_aabb(&body.base)
  return handle, true
}

destroy_trigger :: proc(self: ^World, handle: TriggerHandle) {
  cont.free(&self.trigger_bodies, handle)
}

// Pose and collider setters keep the cached bounds and the broadphase in
// sync. Dynamic bodies are woken so the next `step` refits their BVH leaf;
// static bodies refit the static BVH immediately.
set_dynamic_body_pose :: proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
  position: [3]f32,
  rotation: quaternion128,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.position = position
  body.rotation = rotation
  update_world_inertia(body)
  update_cached_aabb(&body.base)
  wake_up(body)
}

set_static_body_pose :: proc(
  self: ^World,
  handle: StaticRigidBodyHandle,
  position: [3]f32,
  rotation: quaternion128,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.position = position
  body.rotation = rotation
  update_cached_aabb(&body.base)
  refit_static_entry(self, handle, body.cached_aabb)
}

set_trigger_pose :: proc(
  self: ^World,
  handle: TriggerHandle,
  position: [3]f32,
  rotation: quaternion128,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.position = position
  body.rotation = rotation
  update_cached_aabb(&body.base)
}

set_body_pose :: proc {
  set_dynamic_body_pose,
  set_static_body_pose,
  set_trigger_pose,
}

// Also resets the inertia to the new shape at the current mass.
set_dynamic_body_collider :: proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
  collider: Collider,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.collider = collider
  set_inertia_from_collider(body, collider)
  update_cached_aabb(&body.base)
  wake_up(body)
}

set_static_body_collider :: proc(
  self: ^World,
  handle: StaticRigidBodyHandle,
  collider: Collider,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.collider = collider
  update_cached_aabb(&body.base)
  refit_static_entry(self, handle, body.cached_aabb)
}

set_trigger_collider :: proc(
  self: ^World,
  handle: TriggerHandle,
  collider: Collider,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.collider = collider
  update_cached_aabb(&body.base)
}

set_body_collider :: proc {
  set_dynamic_body_collider,
  set_static_body_collider,
  set_trigger_collider,
}

// Velocity setters wake the body.
set_velocity :: proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
  velocity: [3]f32,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.velocity = velocity
  wake_up(body)
}

set_angular_velocity :: proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
  angular_velocity: [3]f32,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.angular_velocity = angular_velocity
  wake_up(body)
}

// Recomputes the inertia from the body's collider at the new mass. Ignores
// mass <= 0.
set_body_mass :: proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
  mass: f32,
) {
  if mass <= 0 do return
  body, ok := get(self, handle)
  if !ok do return
  set_mass(body, mass)
  set_inertia_from_collider(body, body.collider)
}

// The force is held for the next `step` and cleared after it.
apply_force :: proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
  force: [3]f32,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.force += force
  wake_up(body)
}

apply_impulse :: proc(
  self: ^World,
  handle: DynamicRigidBodyHandle,
  impulse: [3]f32,
) {
  body, ok := get(self, handle)
  if !ok do return
  body.velocity += impulse * body.inv_mass
  wake_up(body)
}

// Bodies not yet in the static BVH are picked up by the next rebuild.
@(private = "file")
refit_static_entry :: proc(
  self: ^World,
  handle: StaticRigidBodyHandle,
  bounds: geometry.Aabb,
) {
  for &entry in self.static_bvh.primitives {
    if entry.handle != handle do continue
    entry.bounds = bounds
    geometry.bvh_refit(&self.static_bvh)
    return
  }
}

BodyPose :: struct {
  user:     cont.Handle,
  position: [3]f32,
  rotation: quaternion128,
}

// Poses of awake dynamic bodies that have a `user` link, for copying back
// into a scene graph after `step`.
body_poses :: proc(
  self: ^World,
  allocator := context.temp_allocator,
) -> []BodyPose {
  poses := make([dynamic]BodyPose, 0, len(self.bodies.entries), allocator)
  it := cont.iterator(&self.bodies)
  for body in cont.next(&it, DynamicRigidBodyHandle) {
    if body.is_sleeping || body.user == {} do continue
    append(&poses, BodyPose{body.user, body.position, body.rotation})
  }
  return poses[:]
}
