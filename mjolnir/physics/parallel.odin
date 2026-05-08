package physics

import cont "../containers"
import "../geometry"
import "base:intrinsics"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_THREAD_COUNT :: 16
CCD_VELOCITY_THRESHOLD :: 5.0
CCD_VELOCITY_THRESHOLD_SQ :: CCD_VELOCITY_THRESHOLD * CCD_VELOCITY_THRESHOLD

pool_wait :: proc(pool: ^thread.Pool) {
  for {
    task, ok := thread.pool_pop_waiting(pool)
    if !ok do break
    thread.pool_do_work(pool, task)
  }
  for thread.pool_num_outstanding(pool) > 0 {
    intrinsics.cpu_relax()
  }
}

BVH_Refit_Task_Data :: struct {
  physics: ^World,
  start:   int,
  end:     int,
}

CCD_Work_Queue :: struct {
  current_index: i32,
  total_count:   int,
}

CCD_Task_Data_Dynamic :: struct {
  physics:          ^World,
  work_queue:       ^CCD_Work_Queue,
  dt:               f32,
  ccd_handled:      []bool,
  bodies_tested:    int,
  total_candidates: int,
}

Prepare_Task_Data :: struct {
  physics: ^World,
  start:   int,
  end:     int,
  dt:      f32,
}

prepare_dynamic_task :: proc(task: thread.Task) {
  data := (^Prepare_Task_Data)(task.data)
  contacts := data.physics.dynamic_contacts[:]
  #no_bounds_check for i in data.start ..< data.end {
    c := &contacts[i]
    body_a := get(data.physics, c.body_a) or_continue
    body_b := get(data.physics, c.body_b) or_continue
    prepare_contact(c, body_a, body_b, data.dt)
  }
}

prepare_static_task :: proc(task: thread.Task) {
  data := (^Prepare_Task_Data)(task.data)
  contacts := data.physics.static_contacts[:]
  #no_bounds_check for i in data.start ..< data.end {
    c := &contacts[i]
    body_a := get(data.physics, c.body_a) or_continue
    body_b := get(data.physics, c.body_b) or_continue
    prepare_contact(c, body_a, body_b, data.dt)
  }
}

sequential_prepare_contacts :: proc(world: ^World, dt: f32) {
  for &c in world.dynamic_contacts {
    a := get(world, c.body_a) or_continue
    b := get(world, c.body_b) or_continue
    prepare_contact(&c, a, b, dt)
  }
  for &c in world.static_contacts {
    a := get(world, c.body_a) or_continue
    b := get(world, c.body_b) or_continue
    prepare_contact(&c, a, b, dt)
  }
}

parallel_prepare_contacts :: proc(world: ^World, dt: f32, num_threads := DEFAULT_THREAD_COUNT) {
  dyn_count := len(world.dynamic_contacts)
  sta_count := len(world.static_contacts)
  total := dyn_count + sta_count
  if total < 200 || num_threads <= 1 {
    sequential_prepare_contacts(world, dt)
    return
  }
  task_data := make([]Prepare_Task_Data, num_threads * 2, context.temp_allocator)
  task_idx := 0
  if dyn_count > 0 {
    chunk := (dyn_count + num_threads - 1) / num_threads
    for i in 0 ..< num_threads {
      s := i * chunk
      if s >= dyn_count do break
      e := min(s + chunk, dyn_count)
      task_data[task_idx] = Prepare_Task_Data{physics = world, start = s, end = e, dt = dt}
      thread.pool_add_task(&world.thread_pool, mem.nil_allocator(), prepare_dynamic_task, &task_data[task_idx], task_idx)
      task_idx += 1
    }
  }
  if sta_count > 0 {
    chunk := (sta_count + num_threads - 1) / num_threads
    for i in 0 ..< num_threads {
      s := i * chunk
      if s >= sta_count do break
      e := min(s + chunk, sta_count)
      task_data[task_idx] = Prepare_Task_Data{physics = world, start = s, end = e, dt = dt}
      thread.pool_add_task(&world.thread_pool, mem.nil_allocator(), prepare_static_task, &task_data[task_idx], task_idx)
      task_idx += 1
    }
  }
  pool_wait(&world.thread_pool)
}

refit_range :: #force_inline proc(physics: ^World, start, end: int) {
  #no_bounds_check for i in start ..< end {
    bvh_entry := &physics.dynamic_bvh.primitives[i]
    body := get(physics, bvh_entry.handle) or_continue
    if body.is_killed || body.is_sleeping do continue
    bvh_entry.bounds = body.cached_aabb
  }
}

bvh_refit_task :: proc(task: thread.Task) {
  data := (^BVH_Refit_Task_Data)(task.data)
  refit_range(data.physics, data.start, data.end)
}

parallel_bvh_refit :: proc(
  physics: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  primitive_count := len(physics.dynamic_bvh.primitives)
  if primitive_count == 0 do return
  if primitive_count < 100 || num_threads == 1 {
    sequential_bvh_refit(physics)
    return
  }
  chunk_size := (primitive_count + num_threads - 1) / num_threads
  task_data_array := make(
    []BVH_Refit_Task_Data,
    num_threads,
    context.temp_allocator,
  )
  for i in 0 ..< num_threads {
    start := i * chunk_size
    end := min(start + chunk_size, primitive_count)
    if start >= primitive_count do break
    task_data_array[i] = BVH_Refit_Task_Data {
      physics = physics,
      start   = start,
      end     = end,
    }
    thread.pool_add_task(
      &physics.thread_pool,
      mem.nil_allocator(),
      bvh_refit_task,
      &task_data_array[i],
      i,
    )
  }
  pool_wait(&physics.thread_pool)
  geometry.bvh_refit(&physics.dynamic_bvh)
}

sequential_bvh_refit :: proc(physics: ^World) {
  refit_range(physics, 0, len(physics.dynamic_bvh.primitives))
  geometry.bvh_refit(&physics.dynamic_bvh)
}

// Process one dynamic-dynamic broadphase pair into a contact. Returns 1 if narrowphase test was run.
narrowphase_dynamic_pair :: #force_inline proc(
  physics: ^World,
  pair: geometry.BVHOverlapPair(DynamicBroadPhaseEntry),
  out: ^[dynamic]DynamicContact,
) -> (narrow_tests: int) {
  handle_a := pair.a.handle
  handle_b := pair.b.handle
  body_a := get(physics, handle_a) or_else nil
  body_b := get(physics, handle_b) or_else nil
  if body_a == nil || body_b == nil do return
  if body_a.is_killed || body_b.is_killed do return
  if body_a.is_sleeping && body_b.is_sleeping do return
  if !bounding_spheres_intersect(
    body_a.cached_sphere_center, body_a.cached_sphere_radius,
    body_b.cached_sphere_center, body_b.cached_sphere_radius,
  ) {
    return
  }
  narrow_tests = 1
  point, normal, penetration, hit := test_collision(body_a, body_b)
  if !hit do return
  if body_a.is_sleeping do wake_up(body_a)
  if body_b.is_sleeping do wake_up(body_b)
  contact := DynamicContact {
    body_a      = handle_a,
    body_b      = handle_b,
    point       = point,
    normal      = normal,
    penetration = penetration,
    restitution = (body_a.restitution + body_b.restitution) * 0.5,
    friction    = (body_a.friction + body_b.friction) * 0.5,
  }
  hash := collision_pair_hash(handle_a, handle_b)
  if w, found := physics.prev_dynamic_warmstart[hash]; found {
    contact.normal_impulse = w.normal * WARMSTART_COEF
    contact.tangent_impulse = w.tangent * WARMSTART_COEF
  }
  append(out, contact)
  return
}

narrowphase_static_pair :: #force_inline proc(
  physics: ^World,
  pair: geometry.BVHCrossPair(DynamicBroadPhaseEntry, StaticBroadPhaseEntry),
  out: ^[dynamic]StaticContact,
) -> (narrow_tests: int) {
  handle_a := pair.a.handle
  handle_b := pair.b.handle
  body_a := get(physics, handle_a) or_else nil
  body_b := get(physics, handle_b) or_else nil
  if body_a == nil || body_b == nil do return
  if body_a.is_killed || body_a.is_sleeping do return
  if !bounding_spheres_intersect(
    body_a.cached_sphere_center, body_a.cached_sphere_radius,
    body_b.cached_sphere_center, body_b.cached_sphere_radius,
  ) {
    return
  }
  narrow_tests = 1
  point, normal, penetration, hit := test_collision(body_a, body_b)
  if !hit do return
  if body_a.is_sleeping do wake_up(body_a)
  contact := StaticContact {
    body_a      = handle_a,
    body_b      = handle_b,
    point       = point,
    normal      = normal,
    penetration = penetration,
    restitution = (body_a.restitution + body_b.restitution) * 0.5,
    friction    = (body_a.friction + body_b.friction) * 0.5,
  }
  hash := collision_pair_hash(handle_a, handle_b)
  if w, found := physics.prev_static_warmstart[hash]; found {
    contact.normal_impulse = w.normal * WARMSTART_COEF
    contact.tangent_impulse = w.tangent * WARMSTART_COEF
  }
  append(out, contact)
  return
}

broadphase_collect_pairs :: proc(physics: ^World) -> (
  dynamic_pairs: [dynamic]geometry.BVHOverlapPair(DynamicBroadPhaseEntry),
  static_pairs: [dynamic]geometry.BVHCrossPair(DynamicBroadPhaseEntry, StaticBroadPhaseEntry),
) {
  dynamic_pairs = make([dynamic]geometry.BVHOverlapPair(DynamicBroadPhaseEntry), context.temp_allocator)
  static_pairs = make([dynamic]geometry.BVHCrossPair(DynamicBroadPhaseEntry, StaticBroadPhaseEntry), context.temp_allocator)
  geometry.bvh_find_all_overlaps(&physics.dynamic_bvh, &dynamic_pairs)
  geometry.bvh_find_cross_overlaps(&physics.dynamic_bvh, &physics.static_bvh, &static_pairs)
  return
}

sequential_collision_detection_traversal :: proc(physics: ^World) {
  dynamic_pairs, static_pairs := broadphase_collect_pairs(physics)
  for pair in dynamic_pairs do narrowphase_dynamic_pair(physics, pair, &physics.dynamic_contacts)
  for pair in static_pairs do narrowphase_static_pair(physics, pair, &physics.static_contacts)
}

ccd_step_body :: proc(
  physics: ^World,
  body_a: ^DynamicRigidBody,
  idx_a: int,
  dt: f32,
  ccd_handled: []bool,
  dyn_candidates: ^[dynamic]DynamicBroadPhaseEntry,
  static_candidates: ^[dynamic]StaticBroadPhaseEntry,
) -> (tested: bool, candidate_count: int) {
  if body_a.is_killed || body_a.is_sleeping do return
  collider_a := &body_a.collider
  velocity_mag_sq := linalg.length2(body_a.velocity)
  if velocity_mag_sq < CCD_VELOCITY_THRESHOLD_SQ do return
  tested = true
  motion := body_a.velocity * dt
  earliest_toi := f32(1.0)
  earliest_normal := linalg.VECTOR3F32_Y_AXIS
  earliest_body_dyn: ^DynamicRigidBody
  earliest_body_static: ^StaticRigidBody
  has_ccd_hit := false
  swept_aabb := geometry.Aabb {
    min = linalg.min(body_a.cached_aabb.min, body_a.cached_aabb.min + motion),
    max = linalg.max(body_a.cached_aabb.max, body_a.cached_aabb.max + motion),
  }
  clear(dyn_candidates)
  geometry.bvh_query_aabb(&physics.dynamic_bvh, swept_aabb, dyn_candidates)
  candidate_count = len(dyn_candidates)
  for candidate in dyn_candidates {
    handle_b := candidate.handle
    if u32(idx_a) == handle_b.index do continue
    body_b := get(physics, handle_b) or_continue
    toi := swept_test(collider_a, &body_b.collider, body_a.position, body_b.position, body_a.rotation, body_b.rotation, motion)
    if toi.has_impact && toi.time < earliest_toi {
      earliest_toi = toi.time
      earliest_normal = toi.normal
      earliest_body_dyn = body_b
      earliest_body_static = nil
      has_ccd_hit = true
    }
  }
  clear(static_candidates)
  geometry.bvh_query_aabb(&physics.static_bvh, swept_aabb, static_candidates)
  candidate_count += len(static_candidates)
  for candidate in static_candidates {
    body_b := get(physics, candidate.handle) or_continue
    toi := swept_test(collider_a, &body_b.collider, body_a.position, body_b.position, body_a.rotation, body_b.rotation, motion)
    if toi.has_impact && toi.time < earliest_toi {
      earliest_toi = toi.time
      earliest_normal = toi.normal
      earliest_body_dyn = nil
      earliest_body_static = body_b
      has_ccd_hit = true
    }
  }
  if !(has_ccd_hit && earliest_toi > 0.01 && earliest_toi < 0.99) do return
  safe_time := earliest_toi * 0.98
  body_a.position += body_a.velocity * dt * safe_time
  update_cached_aabb(&body_a.base)
  vel_along_normal := linalg.dot(body_a.velocity, earliest_normal)
  if vel_along_normal < 0 {
    wake_up(body_a)
    if earliest_body_dyn != nil do wake_up(earliest_body_dyn)
    restitution := body_a.restitution
    friction := body_a.friction
    if earliest_body_dyn != nil {
      restitution = (body_a.restitution + earliest_body_dyn.restitution) * 0.5
      friction = (body_a.friction + earliest_body_dyn.friction) * 0.5
    } else if earliest_body_static != nil {
      restitution = (body_a.restitution + earliest_body_static.restitution) * 0.5
      friction = (body_a.friction + earliest_body_static.friction) * 0.5
    }
    body_a.velocity -= earliest_normal * vel_along_normal * (1.0 + restitution)
    tangent_vel := body_a.velocity - earliest_normal * linalg.dot(body_a.velocity, earliest_normal)
    body_a.velocity -= tangent_vel * friction * 0.5
  }
  ccd_handled[idx_a] = true
  return
}

ccd_task_dynamic :: proc(task: thread.Task) {
  data := (^CCD_Task_Data_Dynamic)(task.data)
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, 0, 64, context.temp_allocator)
  static_candidates := make([dynamic]StaticBroadPhaseEntry, 0, 64, context.temp_allocator)
  BATCH_SIZE :: 32
  for {
    start_idx := int(sync.atomic_add(&data.work_queue.current_index, i32(BATCH_SIZE)))
    if start_idx >= data.work_queue.total_count do break
    end_idx := min(start_idx + BATCH_SIZE, data.work_queue.total_count)
    #no_bounds_check for idx_a in start_idx ..< end_idx {
      if idx_a >= len(data.physics.bodies.entries) do break
      entry_a := &data.physics.bodies.entries[idx_a]
      if !entry_a.active do continue
      tested, cands := ccd_step_body(data.physics, &entry_a.item, idx_a, data.dt, data.ccd_handled, &dyn_candidates, &static_candidates)
      if tested do data.bodies_tested += 1
      data.total_candidates += cands
    }
  }
}

parallel_ccd :: proc(
  physics: ^World,
  dt: f32,
  ccd_handled: []bool,
  num_threads := DEFAULT_THREAD_COUNT,
) -> (
  bodies_tested: int,
  total_candidates: int,
) {
  body_count := len(physics.bodies.entries)
  if body_count == 0 do return
  if body_count < 100 || num_threads == 1 {
    return sequential_ccd(physics, dt, ccd_handled)
  }
  work_queue := CCD_Work_Queue {
    current_index = 0,
    total_count   = body_count,
  }
  task_data_array := make(
    []CCD_Task_Data_Dynamic,
    num_threads,
    context.temp_allocator,
  )
  for i in 0 ..< num_threads {
    task_data_array[i] = CCD_Task_Data_Dynamic {
      physics     = physics,
      work_queue  = &work_queue,
      dt          = dt,
      ccd_handled = ccd_handled,
    }
    thread.pool_add_task(
      &physics.thread_pool,
      mem.nil_allocator(),
      ccd_task_dynamic,
      &task_data_array[i],
      i,
    )
  }
  pool_wait(&physics.thread_pool)
  for &task_data in task_data_array {
    bodies_tested += task_data.bodies_tested
    total_candidates += task_data.total_candidates
  }
  return
}

sequential_ccd :: proc(
  physics: ^World,
  dt: f32,
  ccd_handled: []bool,
) -> (bodies_tested: int, total_candidates: int) {
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, 0, 64, context.temp_allocator)
  static_candidates := make([dynamic]StaticBroadPhaseEntry, 0, 64, context.temp_allocator)
  #no_bounds_check for &entry_a, idx_a in physics.bodies.entries do if entry_a.active {
    tested, cands := ccd_step_body(physics, &entry_a.item, idx_a, dt, ccd_handled, &dyn_candidates, &static_candidates)
    if tested do bodies_tested += 1
    total_candidates += cands
  }
  return
}

// Collision detection using BVH tree traversal (O(N) instead of O(N log N))
// This finds all overlapping pairs in a single tree traversal
Collision_Detection_Task_Data_Traversal :: struct {
  physics:            ^World,
  dynamic_pairs:      []geometry.BVHOverlapPair(DynamicBroadPhaseEntry),
  static_pairs:       []geometry.BVHCrossPair(DynamicBroadPhaseEntry, StaticBroadPhaseEntry),
  start:              int,
  end:                int,
  dynamic_contacts:   [dynamic]DynamicContact,
  static_contacts:    [dynamic]StaticContact,
  // Thread timing instrumentation
  thread_id:          int,
  elapsed_time:       time.Duration,
  pairs_tested:       int,
  narrow_phase_tests: int,
}

collision_detection_task_traversal :: proc(task: thread.Task) {
  data := (^Collision_Detection_Task_Data_Traversal)(task.data)
  task_start := time.now()
  defer data.elapsed_time = time.since(task_start)

  // Dynamic pairs in [start, end) clipped to dynamic_pairs range
  dyn_end := min(data.end, len(data.dynamic_pairs))
  #no_bounds_check for i in data.start ..< dyn_end {
    data.pairs_tested += 1
    data.narrow_phase_tests += narrowphase_dynamic_pair(data.physics, data.dynamic_pairs[i], &data.dynamic_contacts)
  }

  static_start := max(0, data.start - len(data.dynamic_pairs))
  static_end := min(data.end - len(data.dynamic_pairs), len(data.static_pairs))
  #no_bounds_check for i in static_start ..< static_end {
    data.pairs_tested += 1
    data.narrow_phase_tests += narrowphase_static_pair(data.physics, data.static_pairs[i], &data.static_contacts)
  }
}

// New collision detection using tree-vs-tree traversal
// This is O(N + K) instead of O(N log N) where K is number of overlapping pairs
parallel_collision_detection_traversal :: proc(
  self: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  parallel_start := time.now()

  if len(self.dynamic_bvh.primitives) == 0 do return

  traversal_start := time.now()
  dynamic_pairs, static_pairs := broadphase_collect_pairs(self)
  traversal_time := time.since(traversal_start)

  total_pairs := len(dynamic_pairs) + len(static_pairs)

  when ENABLE_VERBOSE_LOG {
    log.infof(
      "Tree traversal found %d dynamic pairs + %d static pairs = %d total in %v",
      len(dynamic_pairs),
      len(static_pairs),
      total_pairs,
      traversal_time,
    )
  }

  if total_pairs == 0 do return

  per_thread_dyn_cap := max(64, len(dynamic_pairs) / max(1, num_threads) + 32)
  per_thread_sta_cap := max(64, len(static_pairs) / max(1, num_threads) + 32)

  // If few pairs or single threaded, process sequentially
  if total_pairs < 100 || num_threads == 1 {
    task_data := Collision_Detection_Task_Data_Traversal {
      physics       = self,
      dynamic_pairs = dynamic_pairs[:],
      static_pairs  = static_pairs[:],
      start         = 0,
      end           = total_pairs,
      dynamic_contacts = make([dynamic]DynamicContact, 0, len(dynamic_pairs), context.temp_allocator),
      static_contacts = make([dynamic]StaticContact, 0, len(static_pairs), context.temp_allocator),
    }
    collision_detection_task_traversal(thread.Task{data = &task_data})

    for contact in task_data.dynamic_contacts {
      append(&self.dynamic_contacts, contact)
    }
    for contact in task_data.static_contacts {
      append(&self.static_contacts, contact)
    }
    return
  }

  // Parallel processing of pairs
  setup_start := time.now()
  pairs_per_thread := (total_pairs + num_threads - 1) / num_threads

  task_data_array := make(
    []Collision_Detection_Task_Data_Traversal,
    num_threads,
    context.temp_allocator,
  )

  for i in 0 ..< num_threads {
    start := i * pairs_per_thread
    end := min((i + 1) * pairs_per_thread, total_pairs)
    if start >= total_pairs do break

    task_data_array[i] = Collision_Detection_Task_Data_Traversal {
      physics          = self,
      dynamic_pairs    = dynamic_pairs[:],
      static_pairs     = static_pairs[:],
      start            = start,
      end              = end,
      dynamic_contacts = make([dynamic]DynamicContact, 0, per_thread_dyn_cap, context.temp_allocator),
      static_contacts  = make([dynamic]StaticContact, 0, per_thread_sta_cap, context.temp_allocator),
      thread_id        = i,
    }

    thread.pool_add_task(
      &self.thread_pool,
      context.allocator,
      collision_detection_task_traversal,
      &task_data_array[i],
      i,
    )
  }
  setup_time := time.since(setup_start)

  // Wait for completion
  parallel_exec_start := time.now()
  pool_wait(&self.thread_pool)
  parallel_exec_time := time.since(parallel_exec_start)

  // Collect results
  collection_start := time.now()
  total_pairs_tested := 0
  total_narrow_tests := 0
  min_time := time.Duration(1e10) // 10 billion nano seconds = 10s
  max_time := time.Duration(0)
  total_time := time.Duration(0)

  for &task_data in task_data_array {
    for contact in task_data.dynamic_contacts {
      append(&self.dynamic_contacts, contact)
    }
    for contact in task_data.static_contacts {
      append(&self.static_contacts, contact)
    }
    if task_data.pairs_tested > 0 {
      total_pairs_tested += task_data.pairs_tested
      total_narrow_tests += task_data.narrow_phase_tests
      min_time = min(min_time, task_data.elapsed_time)
      max_time = max(max_time, task_data.elapsed_time)
      total_time += task_data.elapsed_time
    }
  }
  collection_time := time.since(collection_start)
  total_parallel_time := time.since(parallel_start)

  when ENABLE_VERBOSE_LOG {
    avg_time := total_time / time.Duration(num_threads)
    variance_pct := 0.0
    if avg_time > 0 {
      variance_pct = f64(max_time - min_time) / f64(avg_time) * 100.0
    }

    log.infof(
      "Traversal Collision Detection: %d pairs, %d narrow tests, %d contacts in %v (traversal: %v, setup: %v, exec: %v, collect: %v, variance: %.1f%%)",
      total_pairs_tested,
      total_narrow_tests,
      len(self.dynamic_contacts) + len(self.static_contacts),
      total_parallel_time,
      traversal_time,
      setup_time,
      parallel_exec_time,
      collection_time,
      variance_pct,
    )
  }
}
