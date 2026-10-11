package physics

import cont "../containers"
import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:thread"
import "core:time"

// Dynamic bodies that fall below this height are destroyed by `step` and
// reported in `World.killed`.
KILL_Y :: #config(PHYSICS_KILL_Y, -50.0)
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
// Contacts are created while shapes are still this far apart:
// the solver's speculative branch stops approach exactly at touch, preventing
// tunneling at moderate speeds without CCD.
SPECULATIVE_DISTANCE :: 0.02

BodyHandle :: distinct cont.Handle

PerfFrame :: struct {
  total_ms:               f32,
  warmstart_prep_ms:      f32,
  ccd_ms:                 f32,
  bvh_build_ms:           f32,
  substep_total_ms:       f32,
  refit_ms:               f32,
  broadphase_ms:          f32,
  prepare_ms:             f32,
  finalize_ms:            f32,
  cleanup_ms:             f32,
  body_count:             int,
  awake_body_count:       int,
  sleeping_body_count:    int,
  contact_count:          int,
  ccd_bodies_tested:      int,
  ccd_total_candidates:   int,
  bvh_dynamic_node_count: int,
  bvh_static_node_count:  int,
  sensor_overlap_count:   int,
  killed_count:           int,
  rebuilt_dynamic_bvh:    bool,
  rebuilt_static_bvh:     bool,
}

// One solver point of a contact manifold
// base_separation: signed separation from narrowphase (negative =
// penetrating); current separation is recovered per substep from body
// position deltas.
// relative_velocity: normal approach speed captured at prepare, used by the
// post-substep restitution pass.
ContactPoint :: struct {
  point:              [3]f32,
  feature_id:         u32,
  normal_impulse:     f32,
  max_normal_impulse: f32,
  normal_mass:        f32,
  base_separation:    f32,
  relative_velocity:  f32,
  r_a:                [3]f32,
  r_b:                [3]f32,
}

// Up to 4 normal points plus one manifold-level friction constraint (coupled
// 2D tangent at the centroid + twist about the normal). Body A is always
// dynamic; b_dynamic tells whether body B is too.
Contact :: struct {
  body_a:          BodyHandle,
  body_b:          BodyHandle,
  b_dynamic:       bool,
  normal:          [3]f32, // from A to B
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

SensorOverlap :: struct {
  sensor: BodyHandle,
  body:   BodyHandle,
}

// A body destroyed by `step` for falling below KILL_Y. `body` is already
// freed; `user` is its caller link, e.g. the scene node to despawn.
KilledBody :: struct {
  body: BodyHandle,
  user: cont.Handle,
}

World :: struct {
  bodies:               cont.Pool(Body),
  gravity:              [3]f32,
  // Read-only after each step
  contacts:             [dynamic]Contact,
  sensor_overlaps:      [dynamic]SensorOverlap,
  killed:               [dynamic]KilledBody,
  last_perf:            PerfFrame,
  prev_warmstart:       map[u64]ContactWarmstart,
  // Moving bodies (dynamic + kinematic) and static bodies
  dynamic_bvh:          geometry.BVH(BroadPhaseEntry),
  static_bvh:           geometry.BVH(BroadPhaseEntry),
  // Set when bodies are created or change BVH; the next step or query
  // rebuilds that BVH
  dynamic_bvh_dirty:    bool,
  static_bvh_dirty:     bool,
  thread_count:         int,
  thread_pool:          thread.Pool,
  // Dense list of awake moving body indices, rebuilt after narrowphase each
  // frame (narrowphase can wake sleeping bodies). Hot substep loops iterate
  // this instead of branching over the whole pool.
  awake_list:           [dynamic]u32,
  // Solver graph coloring
  solver_color_used:    [dynamic]u64,          // per body: bitmask of colors used
  solver_color_buckets: [dynamic][dynamic]int, // per color: contact indices
  solver_overflow:      [dynamic]int,          // contacts that fit no color; solved single-threaded
  solver_color_count:   int,
}

@(private)
BroadPhaseEntry :: struct {
  handle: BodyHandle,
  bounds: geometry.Aabb,
}

// thread_count: worker threads for step; 0 = one per CPU core, 1 = no pool.
init :: proc(self: ^World, gravity := [3]f32{0, -9.81, 0}, thread_count := 0) -> bool {
  self^ = {}
  cont.init(&self.bodies)
  self.gravity = gravity
  bounds_func :: #force_inline proc(entry: BroadPhaseEntry) -> geometry.Aabb {
    return entry.bounds
  }
  self.dynamic_bvh.bounds_func = bounds_func
  self.static_bvh.bounds_func = bounds_func
  self.thread_count = thread_count > 0 ? thread_count : os.get_processor_core_count()
  if self.thread_count > 1 {
    thread.pool_init(&self.thread_pool, context.allocator, self.thread_count)
    thread.pool_start(&self.thread_pool)
    log.infof("physics: thread pool started with %d threads", self.thread_count)
  }
  return true
}

shutdown :: proc(self: ^World) {
  if self.thread_count > 1 {
    thread.pool_join(&self.thread_pool)
    thread.pool_destroy(&self.thread_pool)
  }
  cont.destroy(&self.bodies, proc(body: ^Body) {})
  delete(self.contacts)
  delete(self.sensor_overlaps)
  delete(self.killed)
  delete(self.prev_warmstart)
  delete(self.awake_list)
  delete(self.solver_color_used)
  for &b in self.solver_color_buckets do delete(b)
  delete(self.solver_color_buckets)
  delete(self.solver_overflow)
  geometry.bvh_destroy(&self.dynamic_bvh)
  geometry.bvh_destroy(&self.static_bvh)
  self^ = {}
}

// Destroys every body; the world stays ready for reuse.
teardown :: proc(self: ^World) {
  it := cont.iterator(&self.bodies)
  for _, handle in cont.next(&it, BodyHandle) do destroy_body(self, handle)
  clear(&self.contacts)
  clear(&self.sensor_overlaps)
  clear(&self.killed)
  clear(&self.prev_warmstart)
  clear(&self.awake_list)
  self.dynamic_bvh_dirty = true
  self.static_bvh_dirty = true
}

// mass > 0 makes a dynamic body; mass = 0 an infinite-mass one (static
// until moved, see Body). A sensor ignores mass.
create_body :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  collider: Collider = {},
  mass: f32 = 0,
  is_sensor := false,
  user: cont.Handle = {},
) -> (
  handle: BodyHandle,
  ok: bool,
) #optional_ok {
  body: ^Body
  handle, body = cont.alloc(&self.bodies, BodyHandle) or_return
  body_init(body, position, rotation, collider, mass, is_sensor, user)
  mark_bvh_dirty(self, body)
  return handle, true
}

destroy_body :: proc(self: ^World, handle: BodyHandle) {
  cont.free(&self.bodies, handle)
}

get_body :: #force_inline proc(self: ^World, handle: BodyHandle) -> (ret: ^Body, ok: bool) #optional_ok {
  return cont.get(self.bodies, handle)
}

@(private)
mark_bvh_dirty :: #force_inline proc(self: ^World, body: ^Body) {
  if body.is_sensor do return
  if body.moving {
    self.dynamic_bvh_dirty = true
  } else {
    self.static_bvh_dirty = true
  }
}

// Moving an infinite-mass static body turns it kinematic.
@(private)
start_moving :: proc(self: ^World, body: ^Body) {
  if body.moving || body.is_sensor do return
  body.moving = true
  self.dynamic_bvh_dirty = true
  self.static_bvh_dirty = true
}

// Teleports the body and wakes it. A static body becomes kinematic.
set_pose :: proc(self: ^World, handle: BodyHandle, position: [3]f32, rotation: quaternion128) {
  body, ok := get_body(self, handle)
  if !ok do return
  start_moving(self, body)
  body.position = position
  body.rotation = rotation
  update_world_inertia(body)
  update_cached_aabb(body)
  wake_up(body)
}

// Also resets the inertia to the new shape at the current mass.
set_collider :: proc(self: ^World, handle: BodyHandle, collider: Collider) {
  body, ok := get_body(self, handle)
  if !ok do return
  body.collider = collider
  update_inertia(body)
  update_cached_aabb(body)
  wake_up(body)
  if !body.moving do self.static_bvh_dirty = true
}

// mass > 0 makes the body dynamic, mass = 0 freezes it as kinematic.
// Recomputes the inertia from the collider. Ignored for sensors.
set_mass :: proc(self: ^World, handle: BodyHandle, mass: f32) {
  body, ok := get_body(self, handle)
  if !ok do return
  if body.is_sensor do return
  start_moving(self, body)
  body.inv_mass = mass > 0 ? 1.0 / mass : 0
  if mass <= 0 {
    body.velocity = {}
    body.angular_velocity = {}
  }
  update_inertia(body)
}

// Velocity setters wake the body. A static body becomes kinematic.
set_velocity :: proc(self: ^World, handle: BodyHandle, velocity: [3]f32) {
  body, ok := get_body(self, handle)
  if !ok do return
  start_moving(self, body)
  body.velocity = velocity
  wake_up(body)
}

set_angular_velocity :: proc(self: ^World, handle: BodyHandle, angular_velocity: [3]f32) {
  body, ok := get_body(self, handle)
  if !ok do return
  start_moving(self, body)
  body.angular_velocity = angular_velocity
  wake_up(body)
}

// The force is held for the next `step` and cleared after it. Only dynamic
// bodies respond.
apply_force :: proc(self: ^World, handle: BodyHandle, force: [3]f32) {
  body, ok := get_body(self, handle)
  if !ok do return
  if !is_dynamic(body) do return
  body.force += force
  wake_up(body)
}

apply_impulse :: proc(self: ^World, handle: BodyHandle, impulse: [3]f32) {
  body, ok := get_body(self, handle)
  if !ok do return
  if !is_dynamic(body) do return
  body.velocity += impulse * body.inv_mass
  wake_up(body)
}

BodyPose :: struct {
  user:     cont.Handle,
  position: [3]f32,
  rotation: quaternion128,
}

// Poses of awake moving bodies that have a `user` link, for copying back
// into a scene graph after `step`.
body_poses :: proc(self: ^World, allocator := context.temp_allocator) -> []BodyPose {
  poses := make([dynamic]BodyPose, 0, len(self.awake_list), allocator)
  it := cont.iterator(&self.bodies)
  for body in cont.next(&it, BodyHandle) {
    if !body.moving || body.is_sleeping || body.user == {} do continue
    append(&poses, BodyPose{body.user, body.position, body.rotation})
  }
  return poses[:]
}

// Rebuilds dirty BVHs; destroyed bodies are dropped here.
@(private)
refresh_broadphase :: proc(self: ^World) -> (rebuilt_dynamic, rebuilt_static: bool) {
  if !self.dynamic_bvh_dirty && !self.static_bvh_dirty do return
  dynamic_entries := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  static_entries := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  it := cont.iterator(&self.bodies)
  for body, handle in cont.next(&it, BodyHandle) {
    if body.is_sensor do continue
    update_cached_aabb(body)
    if body.moving {
      append(&dynamic_entries, BroadPhaseEntry{handle, fat_aabb(body)})
    } else {
      append(&static_entries, BroadPhaseEntry{handle, body.cached_aabb})
    }
  }
  build :: proc(self: ^World, bvh: ^geometry.BVH(BroadPhaseEntry), entries: []BroadPhaseEntry) {
    clear(&bvh.nodes)
    clear(&bvh.primitives)
    if self.thread_count > 1 {
      geometry.bvh_build_parallel(bvh, entries, &self.thread_pool, 4, 1000)
    } else {
      geometry.bvh_build(bvh, entries, 4)
    }
  }
  if self.dynamic_bvh_dirty {
    build(self, &self.dynamic_bvh, dynamic_entries[:])
    self.dynamic_bvh_dirty = false
    rebuilt_dynamic = true
  }
  if self.static_bvh_dirty {
    build(self, &self.static_bvh, static_entries[:])
    self.static_bvh_dirty = false
    rebuilt_static = true
  }
  return
}

@(private)
step_warmstart_prep :: proc(self: ^World) {
  clear(&self.prev_warmstart)
  for &contact in self.contacts {
    if !contact_has_impulse(&contact) do continue
    self.prev_warmstart[collision_pair_hash(contact.body_a, contact.body_b)] = contact_store_warmstart(&contact)
  }
}

// Island-based sleeping (end of frame, post-solve velocities): bodies linked
// by dynamic-dynamic contacts sleep only when EVERY island member has been
// quiet for SLEEP_TIME_THRESHOLD. Per-body sleep leaves boxes floating when
// their support dozes off first; per-island can't. Kinematic bodies are
// their own island.
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
  for &c in self.contacts {
    if !c.b_dynamic do continue
    ra := find(parent, i32(c.body_a.index))
    rb := find(parent, i32(c.body_b.index))
    if ra != rb do parent[rb] = ra
  }
  // Per-body quiet timers and island-minimum quiet time
  island_min := make([]f32, n, context.temp_allocator)
  for i in 0 ..< n do island_min[i] = math.F32_MAX
  it := cont.iterator(&self.bodies)
  for body, handle in cont.next(&it, BodyHandle) {
    if !body.moving do continue
    if linalg.length2(body.velocity) < SLEEP_LINEAR_THRESHOLD_SQ &&
       linalg.length2(body.angular_velocity) < SLEEP_ANGULAR_THRESHOLD_SQ {
      body.sleep_timer += dt
    } else {
      body.sleep_timer = 0
      body.is_sleeping = false
    }
    root := find(parent, i32(handle.index))
    island_min[root] = min(island_min[root], body.sleep_timer)
  }
  it = cont.iterator(&self.bodies)
  for body, handle in cont.next(&it, BodyHandle) {
    if !body.moving do continue
    if island_min[find(parent, i32(handle.index))] > SLEEP_TIME_THRESHOLD {
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
step_kill :: proc(self: ^World) {
  clear(&self.killed)
  it := cont.iterator(&self.bodies)
  for body, handle in cont.next(&it, BodyHandle) {
    if !is_dynamic(body) || body.position.y >= KILL_Y do continue
    append(&self.killed, KilledBody{handle, body.user})
    destroy_body(self, handle)
  }
  if len(self.killed) > 0 do self.dynamic_bvh_dirty = true
}

@(private)
step_sensors :: proc(self: ^World) {
  clear(&self.sensor_overlaps)
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  it := cont.iterator(&self.bodies)
  for sensor, sensor_handle in cont.next(&it, BodyHandle) {
    if !sensor.is_sensor do continue
    for bvh in ([2]^geometry.BVH(BroadPhaseEntry){&self.dynamic_bvh, &self.static_bvh}) {
      clear(&candidates)
      geometry.bvh_query_aabb(bvh, sensor.cached_aabb, &candidates)
      for candidate in candidates {
        body := get_body(self, candidate.handle) or_continue
        _, hit := collide_bodies(sensor, body)
        if hit do append(&self.sensor_overlaps, SensorOverlap{sensor_handle, candidate.handle})
      }
    }
  }
}

// Millisecond timing blocks compile out with PHYSICS_PERF_STATS=false;
// the durations then stay zero.
step :: proc(self: ^World, dt: f32) {
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
    mark = time.now()
  }

  ccd_handled := make([]bool, len(self.bodies.entries), context.temp_allocator)
  ccd_bodies_tested, ccd_total_candidates := ccd(self, dt, ccd_handled)
  when PHYSICS_PERF_STATS {
    ccd_time = time.since(mark)
    mark = time.now()
  }

  rebuilt_dynamic_bvh, rebuilt_static_bvh := refresh_broadphase(self)
  when PHYSICS_PERF_STATS do bvh_build_time = time.since(mark)

  // Anchor frame-start positions for per-substep separation recovery, and
  // check the all-asleep fast path (nothing can move → skip the pipeline)
  any_awake := false
  it := cont.iterator(&self.bodies)
  for body in cont.next(&it, BodyHandle) {
    body.position0 = body.position
    if body.moving && !body.is_sleeping do any_awake = true
  }

  // All asleep: last frame's contacts stay for warmstart and islands
  if any_awake {
    when PHYSICS_PERF_STATS do mark = time.now()
    clear(&self.contacts)
    bvh_refit(self)
    when PHYSICS_PERF_STATS {
      refit_time = time.since(mark)
      mark = time.now()
    }

    collision_detection(self)
    when PHYSICS_PERF_STATS do broadphase_time = time.since(mark)

    // Narrowphase may have woken sleeping bodies — build the dense awake
    // list only now
    clear(&self.awake_list)
    awake_it := cont.iterator(&self.bodies)
    for body, handle in cont.next(&awake_it, BodyHandle) {
      if body.moving && !body.is_sleeping do append(&self.awake_list, handle.index)
    }

    when PHYSICS_PERF_STATS do mark = time.now()
    prepare_contacts(self)
    when PHYSICS_PERF_STATS {
      prepare_time = time.since(mark)
      mark = time.now()
    }

    run_substep_loop(self, dt / f32(NUM_SUBSTEPS), NUM_SUBSTEPS, ccd_handled)
    when PHYSICS_PERF_STATS {
      substep_time = time.since(mark)
      mark = time.now()
    }

    // Finalize: refresh spatial caches once per frame
    for index in self.awake_list {
      body := &self.bodies.entries[index].item
      body.force = {}
      body.torque = {}
      update_cached_aabb(body)
    }
    when PHYSICS_PERF_STATS do finalize_time = time.since(mark)
  }

  step_kill(self)
  step_sensors(self)

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
    body_count             = cont.count(self.bodies),
    awake_body_count       = awake_body_count,
    sleeping_body_count    = sleeping_body_count,
    contact_count          = len(self.contacts),
    ccd_bodies_tested      = ccd_bodies_tested,
    ccd_total_candidates   = ccd_total_candidates,
    bvh_dynamic_node_count = len(self.dynamic_bvh.nodes),
    bvh_static_node_count  = len(self.static_bvh.nodes),
    sensor_overlap_count   = len(self.sensor_overlaps),
    killed_count           = len(self.killed),
    rebuilt_dynamic_bvh    = rebuilt_dynamic_bvh,
    rebuilt_static_bvh     = rebuilt_static_bvh,
  }
  when ENABLE_VERBOSE_LOG {
    log.infof(
      "Physics: %.2fms total | warmstart=%.2fms ccd=%.2fms bvh=%.2fms [refit=%.2fms collision=%.2fms prep=%.2fms solve=%.2fms finalize=%.2fms] cleanup=%.2fms | bodies=%d awake=%d contacts=%d",
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
      self.last_perf.body_count, awake_body_count, len(self.contacts),
    )
  }
}
