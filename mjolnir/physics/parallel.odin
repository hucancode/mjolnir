package physics

import cont "../containers"
import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_THREAD_COUNT :: 12 // Match physical core count (not hyperthreaded) for best efficiency
WARMSTART_COEF :: 0.8

BVH_Refit_Task_Data :: struct {
  physics: ^World,
  start:   int,
  end:     int,
}

AABB_Cache_Task_Data :: struct {
  physics: ^World,
  start:   int,
  end:     int,
}

Collision_Detection_Task_Data :: struct {
  physics:            ^World,
  start:              int,
  end:                int,
  contacts:           [dynamic]Contact,
  // Thread timing instrumentation
  thread_id:          int,
  elapsed_time:       time.Duration,
  bodies_tested:      int,
  candidates_found:   int,
  narrow_phase_tests: int,
}

// Shared work queue for dynamic load balancing
Collision_Work_Queue :: struct {
  current_index: i32,
  total_count:   int,
}

Collision_Detection_Task_Data_Dynamic :: struct {
  physics:            ^World,
  work_queue:         ^Collision_Work_Queue,
  contacts:           [dynamic]Contact,
  // Thread timing instrumentation
  thread_id:          int,
  elapsed_time:       time.Duration,
  bodies_tested:      int,
  candidates_found:   int,
  narrow_phase_tests: int,
}

CCD_Task_Data :: struct {
  physics:          ^World,
  start:            int,
  end:              int,
  dt:               f32,
  ccd_handled:      []bool,
  bodies_tested:    int,
  total_candidates: int,
  stats_mtx:        ^sync.Mutex,
}

bvh_refit_task :: proc(task: thread.Task) {
  data := (^BVH_Refit_Task_Data)(task.data)
  for i in data.start ..< data.end {
    bvh_entry := &data.physics.spatial_index.primitives[i]
    body := get(data.physics, bvh_entry.handle) or_continue
    bvh_entry.bounds = body.cached_aabb
  }
}

parallel_bvh_refit :: proc(
  physics: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  primitive_count := len(physics.spatial_index.primitives)
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
  for thread.pool_num_outstanding(&physics.thread_pool) > 0 {
      time.sleep(time.Microsecond * 100)
  }
  geometry.bvh_refit(&physics.spatial_index)
}

sequential_bvh_refit :: proc(physics: ^World) {
  for &bvh_entry in physics.spatial_index.primitives {
    body := get(physics, bvh_entry.handle) or_continue
    bvh_entry.bounds = body.cached_aabb
  }
  geometry.bvh_refit(&physics.spatial_index)
}

aabb_cache_update_task :: proc(task: thread.Task) {
  data := (^AABB_Cache_Task_Data)(task.data)
  for i in data.start ..< data.end {
    if i >= len(data.physics.bodies.entries) do break
    entry := &data.physics.bodies.entries[i]
    if !entry.active do continue
    body := &entry.item
    if body.is_sleeping do continue
    collider := get(data.physics, body.collider_handle) or_continue
    update_cached_aabb(body, collider)
  }
}

parallel_update_aabb_cache :: proc(
  physics: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  body_count := len(physics.bodies.entries)
  if body_count == 0 do return
  if body_count < 100 || num_threads == 1 {
    sequential_update_aabb_cache(physics)
    return
  }
  chunk_size := (body_count + num_threads - 1) / num_threads
  task_data_array := make(
    []AABB_Cache_Task_Data,
    num_threads,
    context.temp_allocator,
  )
  for i in 0 ..< num_threads {
    start := i * chunk_size
    end := min(start + chunk_size, body_count)
    if start >= body_count do break
    task_data_array[i] = AABB_Cache_Task_Data {
      physics = physics,
      start   = start,
      end     = end,
    }
    thread.pool_add_task(
      &physics.thread_pool,
      mem.nil_allocator(),
      aabb_cache_update_task,
      &task_data_array[i],
      i,
    )
  }
  for thread.pool_num_outstanding(&physics.thread_pool) > 0 {
      time.sleep(time.Microsecond * 100)
  }
}

sequential_update_aabb_cache :: proc(physics: ^World) {
  for &entry in physics.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_sleeping do continue
    collider := get(physics, body.collider_handle) or_continue
    update_cached_aabb(body, collider)
  }
}

collision_detection_task :: proc(task: thread.Task) {
  data := (^Collision_Detection_Task_Data)(task.data)
  task_start := time.now()
  defer data.elapsed_time = time.since(task_start)
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  for i in data.start ..< data.end {
    bvh_entry := &data.physics.spatial_index.primitives[i]
    handle_a := bvh_entry.handle
    body_a := get(data.physics, handle_a) or_continue
    // Skip query for static or sleeping bodies (they don't initiate collisions)
    if body_a.is_static || body_a.is_sleeping do continue
    data.bodies_tested += 1
    clear(&candidates)
    bvh_query_aabb_fast(
      &data.physics.spatial_index,
      bvh_entry.bounds,
      &candidates,
    )
    data.candidates_found += len(candidates)
    for entry_b in candidates {
      handle_b := entry_b.handle
      if handle_a == handle_b do continue
      body_b := get(data.physics, handle_b) or_continue
      if handle_a.index > handle_b.index && !body_b.is_static && !body_b.is_sleeping do continue
      if body_a.is_static && body_b.is_static do continue
      if body_a.trigger_only || body_b.trigger_only do continue
      collider_a := get(data.physics, body_a.collider_handle) or_continue
      collider_b := get(data.physics, body_b.collider_handle) or_continue
      // Bounding sphere pre-filter: cheap test before expensive narrow phase
      bounding_spheres_intersect(
        body_a.cached_sphere_center,
        body_a.cached_sphere_radius,
        body_b.cached_sphere_center,
        body_b.cached_sphere_radius,
      ) or_continue
      data.narrow_phase_tests += 1
      is_primitive_shape := true
      // TODO: if we have custom physics shape, we must use GJK algorithm, otherwise use a fast path
      point: [3]f32
      normal: [3]f32
      penetration: f32
      hit: bool
      if is_primitive_shape {
        point, normal, penetration, hit = test_collision(
          collider_a,
          body_a.position,
          body_a.rotation,
          collider_b,
          body_b.position,
          body_b.rotation,
        )
      } else {
        point, normal, penetration, hit = test_collision_gjk(
          collider_a,
          body_a.position,
          body_a.rotation,
          collider_b,
          body_b.position,
          body_b.rotation,
        )
      }
      if !hit do continue
      // Wake up bodies involved in collision
      if body_a.is_sleeping do wake_up(body_a)
      if body_b.is_sleeping do wake_up(body_b)
      contact := Contact {
        body_a      = handle_a,
        body_b      = handle_b,
        point       = point,
        normal      = normal,
        penetration = penetration,
        restitution = (body_a.restitution + body_b.restitution) * 0.5,
        friction    = (body_a.friction + body_b.friction) * 0.5,
      }
      hash := collision_pair_hash(handle_a, handle_b)
      if prev_contact, found := data.physics.prev_contacts[hash]; found {
        contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
        contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
      }
      append(&data.contacts, contact)
    }
  }
}

// Dynamic collision detection task - pulls work atomically from shared queue
collision_detection_task_dynamic :: proc(task: thread.Task) {
  data := (^Collision_Detection_Task_Data_Dynamic)(task.data)
  task_start := time.now()
  defer data.elapsed_time = time.since(task_start)
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  BATCH_SIZE :: 32 // Process bodies in batches to reduce atomic contention
  for {
    // Atomically claim next batch of work
    start_idx := i32(sync.atomic_add(&data.work_queue.current_index, i32(BATCH_SIZE)))
    if int(start_idx) >= data.work_queue.total_count do break
    end_idx := min(int(start_idx) + BATCH_SIZE, data.work_queue.total_count)
    for i in int(start_idx) ..< end_idx {
      bvh_entry := &data.physics.spatial_index.primitives[i]
      handle_a := bvh_entry.handle
      body_a := get(data.physics, handle_a) or_continue
      // Skip query for static or sleeping bodies (they don't initiate collisions)
      if body_a.is_static || body_a.is_sleeping do continue
      data.bodies_tested += 1
      clear(&candidates)
      bvh_query_aabb_fast(
        &data.physics.spatial_index,
        bvh_entry.bounds,
        &candidates,
      )
      data.candidates_found += len(candidates)
      for entry_b in candidates {
        handle_b := entry_b.handle
        if handle_a == handle_b do continue
        body_b := get(data.physics, handle_b) or_continue
        if handle_a.index > handle_b.index && !body_b.is_static && !body_b.is_sleeping do continue
        if body_a.is_static && body_b.is_static do continue
        if body_a.trigger_only || body_b.trigger_only do continue
        collider_a := get(data.physics, body_a.collider_handle) or_continue
        collider_b := get(data.physics, body_b.collider_handle) or_continue
        // Bounding sphere pre-filter: cheap test before expensive narrow phase
        bounding_spheres_intersect(
          body_a.cached_sphere_center,
          body_a.cached_sphere_radius,
          body_b.cached_sphere_center,
          body_b.cached_sphere_radius,
        ) or_continue
        data.narrow_phase_tests += 1
        is_primitive_shape := true
        point: [3]f32
        normal: [3]f32
        penetration: f32
        hit: bool
        if is_primitive_shape {
          point, normal, penetration, hit = test_collision(
            collider_a,
            body_a.position,
            body_a.rotation,
            collider_b,
            body_b.position,
            body_b.rotation,
          )
        } else {
          point, normal, penetration, hit = test_collision_gjk(
            collider_a,
            body_a.position,
            body_a.rotation,
            collider_b,
            body_b.position,
            body_b.rotation,
          )
        }
        if !hit do continue
        // Wake up bodies involved in collision
        if body_a.is_sleeping do wake_up(body_a)
        if body_b.is_sleeping do wake_up(body_b)
        contact := Contact {
          body_a      = handle_a,
          body_b      = handle_b,
          point       = point,
          normal      = normal,
          penetration = penetration,
          restitution = (body_a.restitution + body_b.restitution) * 0.5,
          friction    = (body_a.friction + body_b.friction) * 0.5,
        }
        hash := collision_pair_hash(handle_a, handle_b)
        if prev_contact, found := data.physics.prev_contacts[hash]; found {
          contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
          contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
        }
        append(&data.contacts, contact)
      }
    }
  }
}

parallel_collision_detection :: proc(
  self: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  parallel_start := time.now()
  primitive_count := len(self.spatial_index.primitives)
  if primitive_count == 0 do return
  if primitive_count < 100 || num_threads == 1 {
    sequential_collision_detection(self)
    return
  }
  setup_start := time.now()
  // Dynamic work queue - threads pull work atomically to balance load
  work_queue := Collision_Work_Queue {
    current_index = 0,
    total_count   = primitive_count,
  }
  task_data_array := make(
    []Collision_Detection_Task_Data_Dynamic,
    num_threads,
    context.temp_allocator,
  )
  for i in 0 ..< num_threads {
    task_data_array[i] = Collision_Detection_Task_Data_Dynamic {
      physics    = self,
      work_queue = &work_queue,
      contacts   = make([dynamic]Contact, 0, 100, context.temp_allocator),
      thread_id  = i,
    }
    thread.pool_add_task(
      &self.thread_pool,
      context.allocator,
      collision_detection_task_dynamic,
      &task_data_array[i],
      i,
    )
  }
  setup_time := time.since(setup_start)
  parallel_exec_start := time.now()
  // Wait for all tasks without stopping pool (pool_finish would terminate threads)
  for thread.pool_num_outstanding(&self.thread_pool) > 0 {
    time.sleep(time.Microsecond * 100)
  }
  parallel_exec_time := time.since(parallel_exec_start)
  // Collect per-thread statistics
  collection_start := time.now()
  total_bodies_tested := 0
  total_candidates := 0
  total_narrow_tests := 0
  min_time := time.Duration(math.F64_MAX)
  max_time := time.Duration(0)
  total_time := time.Duration(0)

  for &task_data in task_data_array {
    for contact in task_data.contacts {
      append(&self.contacts, contact)
    }
    if task_data.bodies_tested > 0 {
      total_bodies_tested += task_data.bodies_tested
      total_candidates += task_data.candidates_found
      total_narrow_tests += task_data.narrow_phase_tests
      min_time = min(min_time, task_data.elapsed_time)
      max_time = max(max_time, task_data.elapsed_time)
      total_time += task_data.elapsed_time
    }
  }
  collection_time := time.since(collection_start)
  total_parallel_time := time.since(parallel_start)

  // Log detailed thread performance
  avg_time := total_time / time.Duration(num_threads)
  variance_pct := 0.0
  if avg_time > 0 {
    variance_pct = f64(max_time - min_time) / f64(avg_time) * 100.0
  }
  when ENABLE_VERBOSE_LOG {
    log.infof(
      "Thread Timing | min=%.2fms avg=%.2fms max=%.2fms variance=%.1f%%",
      time.duration_milliseconds(min_time),
      time.duration_milliseconds(avg_time),
      time.duration_milliseconds(max_time),
      variance_pct,
    )
    // Log timing breakdown
    actual_pool_threads := len(self.thread_pool.threads)
    speedup := f64(total_time) / f64(parallel_exec_time)
    efficiency := speedup / f64(num_threads) * 100.0
    log.infof(
      "Parallel Timing | total=%.2fms (setup=%.2fms exec=%.2fms collect=%.2fms) | max_thread=%.2fms speedup=%.1fx efficiency=%.1f%% | pool_threads=%d",
      time.duration_milliseconds(total_parallel_time),
      time.duration_milliseconds(setup_time),
      time.duration_milliseconds(parallel_exec_time),
      time.duration_milliseconds(collection_time),
      time.duration_milliseconds(max_time),
      speedup,
      efficiency,
      actual_pool_threads,
    )
  }
}

// Phase 1: Retest persistent contacts from previous frame (no BVH query needed)
retest_persistent_contacts :: proc(
  physics: ^World,
) -> (
  persistent_tested: int,
) {
  tested_pairs := make(map[u64]bool, context.temp_allocator)
  for pair_hash, prev_contact in physics.prev_contacts {
    body_a := get(physics, prev_contact.body_a) or_continue
    body_b := get(physics, prev_contact.body_b) or_continue
    // early rejection
    geometry.aabb_intersects(
      body_a.cached_aabb,
      body_b.cached_aabb,
    ) or_continue
    bounding_spheres_intersect(
      body_a.cached_sphere_center,
      body_a.cached_sphere_radius,
      body_b.cached_sphere_center,
      body_b.cached_sphere_radius,
    ) or_continue
    // Static-static pairs don't need retesting
    if body_a.is_static && body_b.is_static do continue
    if body_a.trigger_only || body_b.trigger_only do continue
    collider_a := get(physics, body_a.collider_handle) or_continue
    collider_b := get(physics, body_b.collider_handle) or_continue
    // Narrow phase
    point, normal, penetration := test_collision(
      collider_a,
      body_a.position,
      body_a.rotation,
      collider_b,
      body_b.position,
      body_b.rotation,
    ) or_continue
    if body_a.is_sleeping do wake_up(body_a)
    if body_b.is_sleeping do wake_up(body_b)
    contact := Contact {
      body_a      = prev_contact.body_a,
      body_b      = prev_contact.body_b,
      point       = point,
      normal      = normal,
      penetration = penetration,
      restitution = (body_a.restitution + body_b.restitution) * 0.5,
      friction    = (body_a.friction + body_b.friction) * 0.5,
    }
    // Warmstart from previous frame
    contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
    contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
    append(&physics.contacts, contact)
    tested_pairs[pair_hash] = true
    persistent_tested += 1
  }
  return
}

sequential_collision_detection :: proc(physics: ^World) {
  // Phase 1: Retest persistent pairs directly (no BVH query)
  persistent_tested := retest_persistent_contacts(physics)
  // Phase 2: Find new pairs via BVH query (exclude already-tested persistent pairs)
  tested_pairs := make(map[u64]bool, context.temp_allocator)
  for contact in physics.contacts {
    hash := collision_pair_hash(contact.body_a, contact.body_b)
    tested_pairs[hash] = true
  }
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  test_collision_time: time.Duration
  test_collision_start := time.now()
  for &bvh_entry in physics.spatial_index.primitives {
    handle_a := bvh_entry.handle
    body_a := get(physics, handle_a) or_continue
    // Skip query for static or sleeping bodies
    if body_a.is_static || body_a.is_sleeping do continue
    clear(&candidates)
    bvh_query_aabb_fast(&physics.spatial_index, bvh_entry.bounds, &candidates)
    for entry_b in candidates {
      handle_b := entry_b.handle
      if handle_a == handle_b do continue
      // Skip pairs already tested in persistent phase
      pair_hash := collision_pair_hash(handle_a, handle_b)
      if tested_pairs[pair_hash] do continue
      body_b := get(physics, handle_b) or_continue
      if handle_a.index > handle_b.index && !body_b.is_static && !body_b.is_sleeping do continue
      if body_a.is_static && body_b.is_static do continue
      if body_a.trigger_only || body_b.trigger_only do continue
      collider_a := get(physics, body_a.collider_handle) or_continue
      collider_b := get(physics, body_b.collider_handle) or_continue
      // Bounding sphere pre-filter: cheap test before expensive narrow phase
      if !bounding_spheres_intersect(body_a.cached_sphere_center, body_a.cached_sphere_radius, body_b.cached_sphere_center, body_b.cached_sphere_radius) do continue
      is_primitive_shape := true
      // TODO: if we have custom physics shape, we must use GJK algorithm, otherwise use a fast path
      point: [3]f32
      normal: [3]f32
      penetration: f32
      hit: bool
      test_collision_start := time.now()
      if is_primitive_shape {
        point, normal, penetration, hit = test_collision(
          collider_a,
          body_a.position,
          body_a.rotation,
          collider_b,
          body_b.position,
          body_b.rotation,
        )
      } else {
        point, normal, penetration, hit = test_collision_gjk(
          collider_a,
          body_a.position,
          body_a.rotation,
          collider_b,
          body_b.position,
          body_b.rotation,
        )
      }
      test_collision_time += time.since(test_collision_start)
      if !hit do continue
      // Wake up bodies involved in collision
      if body_a.is_sleeping do wake_up(body_a)
      if body_b.is_sleeping do wake_up(body_b)
      contact := Contact {
        body_a      = handle_a,
        body_b      = handle_b,
        point       = point,
        normal      = normal,
        penetration = penetration,
        restitution = (body_a.restitution + body_b.restitution) * 0.5,
        friction    = (body_a.friction + body_b.friction) * 0.5,
      }
      hash := collision_pair_hash(handle_a, handle_b)
      if prev_contact, found := physics.prev_contacts[hash]; found {
        contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
        contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
      }
      append(&physics.contacts, contact)
    }
  }
  new_pairs := len(physics.contacts) - persistent_tested
  log.infof(
    "Test collision time: %.2fms | total time %.2fms | persistent=%d new=%d total=%d",
    time.duration_milliseconds(test_collision_time),
    time.duration_milliseconds(time.since(test_collision_start)),
    persistent_tested,
    new_pairs,
    len(physics.contacts),
  )
}


ccd_task :: proc(task: thread.Task) {
  data := (^CCD_Task_Data)(task.data)
  ccd_threshold :: 5.0
  ccd_candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  for idx_a in data.start ..< data.end {
    if idx_a >= len(data.physics.bodies.entries) do break
    entry_a := &data.physics.bodies.entries[idx_a]
    if !entry_a.active do continue
    body_a := &entry_a.item
    if body_a.is_static || body_a.trigger_only || body_a.is_sleeping do continue
    velocity_mag := linalg.length(body_a.velocity)
    if velocity_mag < ccd_threshold do continue
    sync.mutex_lock(data.stats_mtx)
    data.bodies_tested += 1
    sync.mutex_unlock(data.stats_mtx)
    collider_a := get(data.physics, body_a.collider_handle) or_continue
    motion := body_a.velocity * data.dt
    earliest_toi := f32(1.0)
    earliest_normal := linalg.VECTOR3F32_Y_AXIS
    earliest_body_b: ^RigidBody = nil
    has_ccd_hit := false
    current_aabb := body_a.cached_aabb
    swept_aabb := current_aabb
    #unroll for i in 0 ..< 3 {
      if motion[i] < 0 {
        swept_aabb.min[i] += motion[i]
      } else {
        swept_aabb.max[i] += motion[i]
      }
    }
    clear(&ccd_candidates)
    bvh_query_aabb_fast(
      &data.physics.spatial_index,
      swept_aabb,
      &ccd_candidates,
    )
    sync.mutex_lock(data.stats_mtx)
    data.total_candidates += len(ccd_candidates)
    sync.mutex_unlock(data.stats_mtx)
    for candidate in ccd_candidates {
      handle_b := candidate.handle
      if u32(idx_a) == handle_b.index do continue
      body_b := get(data.physics, handle_b) or_continue
      collider_b := get(data.physics, body_b.collider_handle) or_continue
      pos_b := body_b.position
      toi := swept_test(
        collider_a,
        body_a.position,
        body_a.rotation,
        motion,
        collider_b,
        body_b.position,
        body_b.rotation,
      )
      if toi.has_impact && toi.time < earliest_toi {
        earliest_toi = toi.time
        earliest_normal = toi.normal
        earliest_body_b = body_b
        has_ccd_hit = true
      }
    }
    if has_ccd_hit && earliest_toi < 0.99 {
      safe_time := earliest_toi * 0.98
      body_a.position += body_a.velocity * data.dt * safe_time
      update_cached_aabb(body_a, collider_a)
      vel_along_normal := linalg.dot(body_a.velocity, earliest_normal)
      if vel_along_normal < 0 {
        wake_up(body_a)
        if earliest_body_b != nil do wake_up(earliest_body_b)
        restitution := body_a.restitution
        if earliest_body_b != nil {
          restitution =
            (body_a.restitution + earliest_body_b.restitution) * 0.5
        }
        body_a.velocity -=
          earliest_normal * vel_along_normal * (1.0 + restitution)
        friction := body_a.friction
        if earliest_body_b != nil {
          friction = (body_a.friction + earliest_body_b.friction) * 0.5
        }
        tangent_vel :=
          body_a.velocity -
          earliest_normal * linalg.dot(body_a.velocity, earliest_normal)
        body_a.velocity -= tangent_vel * friction * 0.5
      }
      data.ccd_handled[idx_a] = true
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
  chunk_size := (body_count + num_threads - 1) / num_threads
  task_data_array := make([]CCD_Task_Data, num_threads, context.temp_allocator)
  stats_mtx: sync.Mutex
  for i in 0 ..< num_threads {
    start := i * chunk_size
    end := min(start + chunk_size, body_count)
    if start >= body_count do break
    task_data_array[i] = CCD_Task_Data {
      physics     = physics,
      start       = start,
      end         = end,
      dt          = dt,
      ccd_handled = ccd_handled,
      stats_mtx   = &stats_mtx,
    }
    thread.pool_add_task(
      &physics.thread_pool,
      mem.nil_allocator(),
      ccd_task,
      &task_data_array[i],
      i,
    )
  }
  for thread.pool_num_outstanding(&physics.thread_pool) > 0 {
      time.sleep(time.Microsecond * 100)
  }
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
) -> (
  bodies_tested: int,
  total_candidates: int,
) {
  ccd_threshold :: 5.0
  ccd_candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  for &entry_a, idx_a in physics.bodies.entries do if entry_a.active {
    body_a := &entry_a.item
    if body_a.is_static || body_a.trigger_only || body_a.is_sleeping do continue
    velocity_mag := linalg.length(body_a.velocity)
    if velocity_mag < ccd_threshold do continue
    bodies_tested += 1
    collider_a := get(physics, body_a.collider_handle) or_continue
    motion := body_a.velocity * dt
    earliest_toi := f32(1.0)
    earliest_normal := linalg.VECTOR3F32_Y_AXIS
    earliest_body_b: ^RigidBody = nil
    has_ccd_hit := false
    current_aabb := body_a.cached_aabb
    swept_aabb := current_aabb
    #unroll for i in 0 ..< 3 {
      if motion[i] < 0 {
        swept_aabb.min[i] += motion[i]
      } else {
        swept_aabb.max[i] += motion[i]
      }
    }
    clear(&ccd_candidates)
    bvh_query_aabb_fast(&physics.spatial_index, swept_aabb, &ccd_candidates)
    total_candidates += len(ccd_candidates)
    for candidate in ccd_candidates {
      handle_b := candidate.handle
      if u32(idx_a) == handle_b.index do continue
      body_b := get(physics, handle_b) or_continue
      collider_b := get(physics, body_b.collider_handle) or_continue
      toi := swept_test(collider_a, body_a.position, body_a.rotation, motion, collider_b, body_b.position, body_b.rotation)
      if toi.has_impact && toi.time < earliest_toi {
        earliest_toi = toi.time
        earliest_normal = toi.normal
        earliest_body_b = body_b
        has_ccd_hit = true
      }
    }
    if has_ccd_hit && earliest_toi < 0.99 {
      safe_time := earliest_toi * 0.98
      body_a.position += body_a.velocity * dt * safe_time
      update_cached_aabb(body_a, collider_a)
      vel_along_normal := linalg.dot(body_a.velocity, earliest_normal)
      if vel_along_normal < 0 {
        wake_up(body_a)
        if earliest_body_b != nil do wake_up(earliest_body_b)
        restitution := body_a.restitution
        friction := body_a.friction
        if earliest_body_b != nil {
          restitution = (body_a.restitution + earliest_body_b.restitution) * 0.5
          friction = (body_a.friction + earliest_body_b.friction) * 0.5
        }
        body_a.velocity -= earliest_normal * vel_along_normal * (1.0 + restitution)
        tangent_vel := body_a.velocity - earliest_normal * linalg.dot(body_a.velocity, earliest_normal)
        body_a.velocity -= tangent_vel * friction * 0.5
      }
      ccd_handled[idx_a] = true
    }
  }
  return
}
