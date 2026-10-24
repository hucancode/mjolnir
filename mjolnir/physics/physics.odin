package physics

import "../containers"
import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import si "core:sys/info"
import "core:thread"
import "core:time"

// KILL_Y is the height below which `step` destroys dynamic bodies (see World.killed).
KILL_Y :: #config(PHYSICS_KILL_Y, -50.0)
// MAX_STEP_DT is the longest time one `step` simulates; a longer dt (a stalled frame) is cut to it,
// so the simulation slows down instead of breaking.
MAX_STEP_DT :: #config(PHYSICS_MAX_STEP_DT, 1.0 / 30.0)
@(private = "file")
NUM_SUBSTEPS :: 4
@(private = "file")
SLEEP_LINEAR_THRESHOLD :: 0.05
@(private = "file")
SLEEP_ANGULAR_THRESHOLD :: 0.05
@(private = "file")
SLEEP_LINEAR_THRESHOLD_SQ :: SLEEP_LINEAR_THRESHOLD * SLEEP_LINEAR_THRESHOLD
@(private = "file")
SLEEP_ANGULAR_THRESHOLD_SQ :: SLEEP_ANGULAR_THRESHOLD * SLEEP_ANGULAR_THRESHOLD
@(private = "file")
SLEEP_TIME_THRESHOLD :: 0.5
@(private = "file")
ENABLE_VERBOSE_LOG :: #config(PHYSICS_VERBOSE_LOG, false)
// PHYSICS_PERF_STATS enables the PerfFrame millisecond timings; set false to compile them out.
PHYSICS_PERF_STATS :: #config(PHYSICS_PERF_STATS, true)
@(private)
MAX_LINEAR_SPEED :: #config(PHYSICS_MAX_LINEAR_SPEED, 400.0)
@(private)
MAX_ROTATION_PER_STEP :: 0.25 * math.PI
// Contacts form while shapes are still this far apart, preventing tunneling without CCD.
@(private)
SPECULATIVE_DISTANCE :: 0.02
// Stale BVH entries of destroyed bodies accumulate to this count before a rebuild.
@(private = "file")
BVH_REBUILD_THRESHOLD :: #config(PHYSICS_BVH_REBUILD_THRESHOLD, 512)

// Handle is an untyped handle, the link a body keeps to what it drives (world.Handle is the
// same type).
Handle :: containers.Handle

// BodyHandle is a generational handle to a Body in a World.
BodyHandle :: distinct Handle

// MAX_BODIES is how many bodies a World holds at once.
MAX_BODIES :: #config(PHYSICS_MAX_BODIES, 65536)

// PerfFrame holds the millisecond timings (see PHYSICS_PERF_STATS) and counters of the last step.
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

// ContactPoint is one point of a contact manifold: where it touches, the signed separation
// found by narrowphase (negative = penetrating) and the normal impulse the solver applied.
ContactPoint :: struct {
  point:           [3]f32,
  base_separation: f32,
  normal_impulse:  f32,
  using _:         ContactPoint_Solver,
}

// relative_velocity: normal approach speed captured at prepare, used by the
// post-substep restitution pass. The current separation is recovered per substep
// from body position deltas.
@(private)
ContactPoint_Solver :: struct {
  feature_id:         u32,
  max_normal_impulse: f32,
  normal_mass:        f32,
  relative_velocity:  f32,
  r_a:                [3]f32,
  r_b:                [3]f32,
}

// Contact is a touching pair of bodies: up to 4 points sharing one normal. Body A is
// always dynamic; b_dynamic tells whether body B is too.
Contact :: struct {
  body_a:      BodyHandle,
  body_b:      BodyHandle,
  b_dynamic:   bool,
  normal:      [3]f32, // from A to B
  restitution: f32,
  friction:    f32,
  count:       int,
  points:      [MAX_MANIFOLD_POINTS]ContactPoint,
  using _:     Contact_Solver,
}

// One manifold-level friction constraint: coupled 2D tangent at the centroid + twist
// about the normal.
@(private)
Contact_Solver :: struct {
  tangent1:        [3]f32,
  tangent2:        [3]f32,
  r_a_c:           [3]f32, // centroid offset from body A center
  r_b_c:           [3]f32,
  tangent_impulse: [2]f32,
  twist_impulse:   f32,
  tangent_mass:    matrix[2, 2]f32, // inverse of the coupled tangent K matrix
  twist_mass:      f32,
}

// SensorOverlap pairs a sensor body with a body overlapping it.
SensorOverlap :: struct {
  sensor: BodyHandle,
  body:   BodyHandle,
}

// KilledBody is a body destroyed by `step` for falling below KILL_Y. `body` is already
// freed; `user` is its caller link, e.g. the scene node to destroy.
KilledBody :: struct {
  body: BodyHandle,
  user: Handle,
}

// World owns the bodies, broad-phase BVHs and per-step contact state. init/shutdown own its
// memory and thread pool (application lifetime); teardown empties it between maps.
World :: struct {
  gravity: [3]f32,
  using _: World_State,
}

@(private)
World_State :: struct {
  // what the last step found (contacts, sensor_overlaps, killed, perf)
  contacts:             [dynamic]Contact,
  sensor_overlaps:      [dynamic]SensorOverlap,
  killed:               [dynamic]KilledBody,
  poses:                [dynamic]BodyPose, // body_poses' result
  last_perf:            PerfFrame,
  // indexed by BodyHandle.index; body_slots says which are live
  bodies:               []Body,
  body_slots:           containers.Slots,
  prev_warmstart:       map[u64]ContactWarmstart,
  joints:               []JointData, // indexed by JointHandle.index; joint_slots says which are live
  joint_slots:          containers.Slots,
  // Moving bodies (dynamic + kinematic) and static bodies
  dynamic_bvh:          geometry.BVH(BodyHandle),
  static_bvh:           geometry.BVH(BodyHandle),
  // Set when bodies are created or change BVH; the next step or query
  // rebuilds that BVH
  dynamic_bvh_dirty:    bool,
  static_bvh_dirty:     bool,
  dynamic_bvh_stale:    int,
  thread_count:         int,
  thread_pool:          thread.Pool,
  // awake moving bodies, rebuilt after narrowphase each frame
  awake_list:           [dynamic]u32,
  // Solver graph coloring
  solver_color_used:    [dynamic]u64,          // per body: bitmask of colors used
  solver_color_buckets: [dynamic][dynamic]int, // per color: contact indices
  solver_overflow:      [dynamic]int,          // contacts that fit no color; solved single-threaded
  solver_color_count:   int,
}

// init prepares the world and its thread pool.
// thread_count: worker threads for step; 0 = one per physical CPU core minus
// one (the caller's thread joins in while waiting), 1 = no pool. The solver
// spin-waits at barriers, so oversubscribing cores stalls every worker.
init :: proc(self: ^World, gravity := [3]f32{0, -9.81, 0}, thread_count := 0) -> bool {
  self^ = {}
  containers.slots_init(&self.body_slots, MAX_BODIES)
  self.bodies = make([]Body, MAX_BODIES)
  containers.slots_init(&self.joint_slots, MAX_JOINTS)
  self.joints = make([]JointData, MAX_JOINTS)
  self.gravity = gravity
  self.thread_count = thread_count > 0 ? thread_count : default_thread_count()
  if self.thread_count > 1 {
    thread.pool_init(&self.thread_pool, context.allocator, self.thread_count)
    thread.pool_start(&self.thread_pool)
    log.infof("physics: thread pool started with %d threads", self.thread_count)
  }
  return true
}

@(private)
default_thread_count :: proc() -> int {
  physical, _, ok := si.cpu_core_count()
  return ok ? max(1, physical - 1) : 1
}

// shutdown stops the thread pool and frees everything the world owns.
shutdown :: proc(self: ^World) {
  if self.thread_count > 1 {
    thread.pool_join(&self.thread_pool)
    thread.pool_destroy(&self.thread_pool)
  }
  containers.slots_destroy(&self.body_slots)
  delete(self.bodies)
  containers.slots_destroy(&self.joint_slots)
  delete(self.joints)
  delete(self.contacts)
  delete(self.sensor_overlaps)
  delete(self.killed)
  delete(self.poses)
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

// teardown drops every body at once; the world stays ready for the next map.
teardown :: proc(self: ^World) {
  containers.slots_rewind(&self.body_slots)
  containers.slots_rewind(&self.joint_slots)
  self.dynamic_bvh_stale = 0
  clear(&self.contacts)
  clear(&self.sensor_overlaps)
  clear(&self.killed)
  clear(&self.prev_warmstart)
  clear(&self.awake_list)
  self.dynamic_bvh_dirty = true
  self.static_bvh_dirty = true
}

// body_create adds a body: mass > 0 makes it dynamic, mass = 0 an infinite-mass one (static
// until moved, see Body). A sensor ignores mass.
body_create :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation := linalg.QUATERNIONF32_IDENTITY,
  collider: Collider = {},
  mass: f32 = 0,
  is_sensor := false,
  user: Handle = {},
) -> (
  handle: BodyHandle,
  ok: bool,
) #optional_ok {
  index := containers.slots_alloc(&self.body_slots) or_return
  body := &self.bodies[index]
  body_init(body, position, rotation, collider, mass, is_sensor, user)
  mark_bvh_dirty(self, body)
  return body_handle(self, index), true
}

// body_destroy frees the body behind handle; a stale handle is ignored.
body_destroy :: proc(self: ^World, handle: BodyHandle) {
  body := lookup(self, handle) or_else nil
  if body == nil do return
  if body.moving && !body.is_sensor {
    self.dynamic_bvh_stale += 1
    if self.dynamic_bvh_stale >= BVH_REBUILD_THRESHOLD do self.dynamic_bvh_dirty = true
  }
  joints_destroy_of(self, handle)
  containers.slots_free(&self.body_slots, handle.index)
}

// body returns a copy of the body behind handle, or false if the handle is stale. step
// moves it; change its state with set_pose, set_velocity, apply_force or apply_impulse,
// and its tuning through body_params.
body :: proc(self: ^World, handle: BodyHandle) -> (ret: Body, ok: bool) #optional_ok {
  b := lookup(self, handle) or_return
  return b^, true
}

// body_params returns the tuning of the body behind handle, to edit in place; step only
// reads it.
body_params :: proc(self: ^World, handle: BodyHandle) -> (ret: ^BodyParams, ok: bool) #optional_ok {
  b := lookup(self, handle) or_return
  return &b.params, true
}

@(private)
lookup :: #force_inline proc(self: ^World, handle: BodyHandle) -> (ret: ^Body, ok: bool) #optional_ok {
  if !containers.slots_valid(&self.body_slots, handle) do return nil, false
  return &self.bodies[handle.index], true
}

@(private)
body_handle :: #force_inline proc(self: ^World, index: u32) -> BodyHandle {
  return BodyHandle(containers.slots_handle(&self.body_slots, index))
}

// Bodies are indexed below this; every live index is.
@(private)
body_range :: #force_inline proc(self: ^World) -> int {
  return int(self.body_slots.high_water)
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

// set_pose teleports the body and wakes it. A static body becomes kinematic.
set_pose :: proc(self: ^World, handle: BodyHandle, position: [3]f32, rotation: quaternion128) {
  body, ok := lookup(self, handle)
  if !ok do return
  start_moving(self, body)
  body.position = position
  body.rotation = rotation
  update_world_inertia(body)
  update_cached_aabb(body)
  wake_up(body)
}

// set_collider replaces the body's collider and resets the inertia to the new shape at the current mass.
set_collider :: proc(self: ^World, handle: BodyHandle, collider: Collider) {
  body, ok := lookup(self, handle)
  if !ok do return
  body.collider = collider
  update_inertia(body)
  update_cached_aabb(body)
  wake_up(body)
  if !body.moving do self.static_bvh_dirty = true
}

// set_mass makes the body dynamic for mass > 0, or kinematic for mass = 0.
// Recomputes the inertia from the collider. Ignored for sensors.
set_mass :: proc(self: ^World, handle: BodyHandle, mass: f32) {
  body, ok := lookup(self, handle)
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

// set_velocity sets the body's velocity and wakes it. A static body becomes kinematic.
set_velocity :: proc(self: ^World, handle: BodyHandle, velocity: [3]f32) {
  body, ok := lookup(self, handle)
  if !ok do return
  start_moving(self, body)
  body.velocity = velocity
  wake_up(body)
}

// set_angular_velocity sets the body's angular velocity and wakes it, like set_velocity.
set_angular_velocity :: proc(self: ^World, handle: BodyHandle, angular_velocity: [3]f32) {
  body, ok := lookup(self, handle)
  if !ok do return
  start_moving(self, body)
  body.angular_velocity = angular_velocity
  wake_up(body)
}

// apply_force holds the force for the next `step`, cleared after it. Only dynamic
// bodies respond.
apply_force :: proc(self: ^World, handle: BodyHandle, force: [3]f32) {
  body, ok := lookup(self, handle)
  if !ok do return
  if !is_dynamic(body) do return
  body.force += force
  wake_up(body)
}

// apply_impulse changes a dynamic body's velocity by impulse / mass and wakes it.
apply_impulse :: proc(self: ^World, handle: BodyHandle, impulse: [3]f32) {
  body, ok := lookup(self, handle)
  if !ok do return
  if !is_dynamic(body) do return
  body.velocity += impulse * body.inv_mass
  wake_up(body)
}

// apply_impulse_at is apply_impulse for an impulse applied at a world-space point, so it also
// spins the body.
apply_impulse_at :: proc(self: ^World, handle: BodyHandle, impulse, point: [3]f32) {
  body, ok := lookup(self, handle)
  if !ok do return
  if !is_dynamic(body) do return
  apply_impulse_at_point(body, impulse, point)
  wake_up(body)
}

// BodyPose is a body's position and rotation together with its user link.
BodyPose :: struct {
  user:     Handle,
  position: [3]f32,
  rotation: quaternion128,
}

// body_poses returns the poses of awake moving bodies that have a `user` link, for copying back
// into a scene graph after `step`; valid until the next body_poses or step.
body_poses :: proc(self: ^World) -> []BodyPose {
  clear(&self.poses)
  c: u32
  for i in containers.slots_next(&self.body_slots, &c) {
    body := &self.bodies[i]
    if !body.moving || body.is_sleeping || body.user == {} do continue
    append(&self.poses, BodyPose{body.user, body.position, body.rotation})
  }
  return self.poses[:]
}

// contacts returns the touching pairs the last step found; valid until the next step.
contacts :: proc(self: ^World) -> []Contact {
  return self.contacts[:]
}

// sensor_overlaps returns the bodies inside each sensor after the last step; valid until the
// next step.
sensor_overlaps :: proc(self: ^World) -> []SensorOverlap {
  return self.sensor_overlaps[:]
}

// killed returns the bodies the last step destroyed for falling below KILL_Y, with their user
// links to clean up; valid until the next step.
killed :: proc(self: ^World) -> []KilledBody {
  return self.killed[:]
}

// perf returns the timings and counters of the last step.
perf :: proc(self: ^World) -> PerfFrame {
  return self.last_perf
}

// Rebuilds dirty BVHs; stale entries of destroyed bodies are dropped here.
@(private)
refresh_broadphase :: proc(self: ^World) -> (rebuilt_dynamic, rebuilt_static: bool) {
  if !self.dynamic_bvh_dirty && !self.static_bvh_dirty do return
  dynamic_entries := make([dynamic]BodyHandle, context.temp_allocator)
  static_entries := make([dynamic]BodyHandle, context.temp_allocator)
  dynamic_bounds := make([dynamic]geometry.Aabb, context.temp_allocator)
  static_bounds := make([dynamic]geometry.Aabb, context.temp_allocator)
  c: u32
  for i in containers.slots_next(&self.body_slots, &c) {
    body, handle := &self.bodies[i], body_handle(self, i)
    if body.is_sensor do continue
    update_cached_aabb(body)
    if body.moving {
      append(&dynamic_entries, handle)
      append(&dynamic_bounds, fat_aabb(body))
    } else {
      append(&static_entries, handle)
      append(&static_bounds, body.cached_aabb)
    }
  }
  build :: proc(self: ^World, bvh: ^geometry.BVH(BodyHandle), entries: []BodyHandle, bounds: []geometry.Aabb) {
    if self.thread_count > 1 {
      geometry.bvh_build_parallel(bvh, entries, bounds, &self.thread_pool, 4, 1000)
    } else {
      geometry.bvh_build(bvh, entries, bounds, 4)
    }
  }
  if self.dynamic_bvh_dirty {
    build(self, &self.dynamic_bvh, dynamic_entries[:], dynamic_bounds[:])
    self.dynamic_bvh_dirty = false
    self.dynamic_bvh_stale = 0
    rebuilt_dynamic = true
  }
  if self.static_bvh_dirty {
    build(self, &self.static_bvh, static_entries[:], static_bounds[:])
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
// by dynamic-dynamic contacts or joints sleep only when EVERY island member has been
// quiet for SLEEP_TIME_THRESHOLD. Per-body sleep leaves boxes floating when
// their support dozes off first; per-island can't. Kinematic bodies are
// their own island.
@(private)
step_island_sleep :: proc(self: ^World, dt: f32) -> (awake_count, sleeping_count: int) {
  n := body_range(self)
  if n == 0 do return
  parent := make([]i32, n, context.temp_allocator)
  for i in 0 ..< n do parent[i] = i32(i)
  find :: proc(parent: []i32, x: i32) -> i32 {
    root := x
    for parent[root] != root do root = parent[root]
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
  jc: u32
  for ji in containers.slots_next(&self.joint_slots, &jc) {
    j := &self.joints[ji]
    if j.body_b == {} do continue
    b := lookup(self, j.body_b) or_continue
    if !is_dynamic(b) do continue
    ra := find(parent, i32(j.body_a.index))
    rb := find(parent, i32(j.body_b.index))
    if ra != rb do parent[rb] = ra
  }
  island_min := make([]f32, n, context.temp_allocator)
  for i in 0 ..< n do island_min[i] = math.F32_MAX
  c: u32
  for i in containers.slots_next(&self.body_slots, &c) {
    body := &self.bodies[i]
    if !body.moving do continue
    if linalg.length2(body.velocity) < SLEEP_LINEAR_THRESHOLD_SQ &&
       linalg.length2(body.angular_velocity) < SLEEP_ANGULAR_THRESHOLD_SQ {
      body.sleep_timer += dt
    } else {
      body.sleep_timer = 0
      body.is_sleeping = false
    }
    root := find(parent, i32(i))
    island_min[root] = min(island_min[root], body.sleep_timer)
  }
  c = 0
  for i in containers.slots_next(&self.body_slots, &c) {
    body := &self.bodies[i]
    if !body.moving do continue
    if island_min[find(parent, i32(i))] > SLEEP_TIME_THRESHOLD {
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
  c: u32
  for i in containers.slots_next(&self.body_slots, &c) {
    body, handle := &self.bodies[i], body_handle(self, i)
    if !is_dynamic(body) || body.position.y >= KILL_Y do continue
    append(&self.killed, KilledBody{handle, body.user})
    body_destroy(self, handle)
  }
}

@(private)
step_sensors :: proc(self: ^World) {
  clear(&self.sensor_overlaps)
  candidates := make([dynamic]BodyHandle, context.temp_allocator)
  c: u32
  for i in containers.slots_next(&self.body_slots, &c) {
    sensor, sensor_handle := &self.bodies[i], body_handle(self, i)
    if !sensor.is_sensor do continue
    for bvh in ([2]^geometry.BVH(BodyHandle){&self.dynamic_bvh, &self.static_bvh}) {
      clear(&candidates)
      geometry.bvh_query_aabb(bvh, sensor.cached_aabb, &candidates)
      for candidate in candidates {
        body := lookup(self, candidate) or_continue
        _, hit := collide_bodies(sensor, body)
        if hit do append(&self.sensor_overlaps, SensorOverlap{sensor_handle, candidate})
      }
    }
  }
}

// step advances the simulation by dt seconds, at most MAX_STEP_DT.
// Millisecond timing blocks compile out with PHYSICS_PERF_STATS=false;
// the durations then stay zero.
step :: proc(self: ^World, dt: f32) {
  dt := min(dt, MAX_STEP_DT)
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

  ccd_handled := make([]bool, body_range(self), context.temp_allocator)
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
  c: u32
  for i in containers.slots_next(&self.body_slots, &c) {
    body := &self.bodies[i]
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

    step_wake_joints(self)
    // built after narrowphase and joint waking, which can wake sleeping bodies
    clear(&self.awake_list)
    c = 0
    for i in containers.slots_next(&self.body_slots, &c) {
      body := &self.bodies[i]
      if body.moving && !body.is_sleeping do append(&self.awake_list, i)
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

    for index in self.awake_list {
      body := &self.bodies[index]
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
    body_count             = int(self.body_slots.count),
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

// destroy frees a body, as body_destroy does.
destroy :: proc {
  body_destroy,
}
