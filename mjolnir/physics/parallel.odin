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

DEFAULT_THREAD_COUNT :: 16
WARMSTART_COEF :: 0.8
CCD_THRESHOLD :: 5.0
CCD_THRESHOLD_SQ :: CCD_THRESHOLD * CCD_THRESHOLD

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
  dynamic_contacts:   [dynamic]DynamicContact,
  static_contacts:    [dynamic]StaticContact,
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
  dynamic_contacts:   [dynamic]DynamicContact,
  static_contacts:    [dynamic]StaticContact,
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

bvh_refit_task :: proc(task: thread.Task) {
  data := (^BVH_Refit_Task_Data)(task.data)
  #no_bounds_check for i in data.start ..< data.end {
    bvh_entry := &data.physics.dynamic_bvh.primitives[i]
    body := get(data.physics, bvh_entry.handle) or_continue
    if body.is_killed || body.is_sleeping do continue
    bvh_entry.bounds = body.cached_aabb
  }
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
  for thread.pool_num_outstanding(&physics.thread_pool) > 0 {
    time.sleep(time.Microsecond * 100)
  }
  geometry.bvh_refit(&physics.dynamic_bvh)
}

sequential_bvh_refit :: proc(physics: ^World) {
  for &bvh_entry in physics.dynamic_bvh.primitives {
    body := get(physics, bvh_entry.handle) or_continue
    if body.is_killed || body.is_sleeping do continue
    bvh_entry.bounds = body.cached_aabb
  }
  geometry.bvh_refit(&physics.dynamic_bvh)
}

aabb_cache_update_task :: proc(task: thread.Task) {
  data := (^AABB_Cache_Task_Data)(task.data)
  // SIMD path: Process bodies in batches of 4 for OBB colliders (Box/Cylinder/Fan) with runtime detection
  // Batch buffer for collecting OBB colliders
  obb_batch: [4]geometry.Obb
  body_batch: [4]^DynamicRigidBody
  collider_batch: [4]^Collider
  batch_count := 0
  #no_bounds_check for i in data.start ..< data.end {
    if i >= len(data.physics.bodies.entries) do break
    entry := &data.physics.bodies.entries[i]
    if !entry.active do continue
    body := &entry.item
    if body.is_killed || body.is_sleeping do continue
    // Check if collider needs OBB-to-AABB conversion
    needs_obb := false
    obb: geometry.Obb
    switch sh in body.collider {
    case SphereCollider:
      // Spheres don't need OBB conversion - process directly
      body.cached_aabb = geometry.Aabb {
        min = body.position - sh.radius,
        max = body.position + sh.radius,
      }
      body.cached_sphere_center = body.position
      body.cached_sphere_radius = sh.radius
      continue
    case BoxCollider:
      obb = geometry.Obb {
        center       = body.position,
        half_extents = sh.half_extents,
        rotation     = body.rotation,
      }
      needs_obb = true
    case CylinderCollider:
      r := sh.radius
      h := sh.height * 0.5
      half_extents := [3]f32{r, h, r}
      obb = geometry.Obb {
        center       = body.position,
        half_extents = half_extents,
        rotation     = body.rotation,
      }
      needs_obb = true
    case FanCollider:
      r := sh.radius
      h := sh.height * 0.5
      half_extents := [3]f32{r, h, r}
      obb = geometry.Obb {
        center       = body.position,
        half_extents = half_extents,
        rotation     = body.rotation,
      }
      needs_obb = true
    }
    if needs_obb {
      // Add to batch
      obb_batch[batch_count] = obb
      body_batch[batch_count] = body
      collider_batch[batch_count] = &body.collider
      batch_count += 1

      // Process batch when full
      if batch_count == 4 {
        aabb_batch: [4]geometry.Aabb
        obb_to_aabb_batch4(obb_batch, &aabb_batch)
        // Update bodies with results
        #no_bounds_check #unroll for j in 0 ..< 4 {
          b := body_batch[j]
          b.cached_aabb = aabb_batch[j]
          b.cached_sphere_center = geometry.aabb_center(b.cached_aabb)
          aabb_half_extents := (b.cached_aabb.max - b.cached_aabb.min) * 0.5
          b.cached_sphere_radius = linalg.length(aabb_half_extents)
        }
        batch_count = 0
      }
    }
  }

  // Process remainder
  if batch_count > 0 {
    #no_bounds_check for j in 0 ..< batch_count {
      body := body_batch[j]
      body.cached_aabb = geometry.obb_to_aabb(obb_batch[j])
      body.cached_sphere_center = geometry.aabb_center(body.cached_aabb)
      aabb_half_extents := (body.cached_aabb.max - body.cached_aabb.min) * 0.5
      body.cached_sphere_radius = linalg.length(aabb_half_extents)
    }
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
  for i in 0..<len(physics.bodies.entries) {
    if !physics.bodies.entries[i].active do continue
    body := &physics.bodies.entries[i].item
    if body.is_killed || body.is_sleeping do continue
    collider := &body.collider
    update_cached_aabb(body)
  }
}

collision_detection_task :: proc(task: thread.Task) {
  data := (^Collision_Detection_Task_Data)(task.data)
  task_start := time.now()
  defer data.elapsed_time = time.since(task_start)
  // Pre-allocate with capacity to avoid reallocations
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    0,
    128,
    context.temp_allocator,
  )
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    0,
    128,
    context.temp_allocator,
  )
  #no_bounds_check for i in data.start ..< data.end {
    bvh_entry := &data.physics.dynamic_bvh.primitives[i]
    handle_a := bvh_entry.handle
    body_a := get(data.physics, handle_a) or_continue
    if body_a.is_killed || body_a.is_sleeping do continue
    data.bodies_tested += 1
    // Query dynamic BVH for dynamic-dynamic collisions
    clear(&dyn_candidates)
    bvh_query_aabb_fast(
      &data.physics.dynamic_bvh,
      bvh_entry.bounds,
      &dyn_candidates,
    )
    data.candidates_found += len(dyn_candidates)
    for entry_b in dyn_candidates {
      handle_b := entry_b.handle
      if handle_a == handle_b do continue
      body_b := get(data.physics, handle_b) or_continue
      if handle_a.index > handle_b.index && !body_b.is_sleeping do continue
      if body_a.trigger_only || body_b.trigger_only do continue
      bounding_spheres_intersect(
        body_a.cached_sphere_center,
        body_a.cached_sphere_radius,
        body_b.cached_sphere_center,
        body_b.cached_sphere_radius,
      ) or_continue
      data.narrow_phase_tests += 1
      point, normal, penetration, hit := test_collision(body_a, body_b)
      if !hit do continue
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
      if prev_contact, found := data.physics.prev_dynamic_contacts[hash];
         found {
        contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
        contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
      }
      append(&data.dynamic_contacts, contact)
    }
    // Query static BVH for dynamic-static collisions
    clear(&static_candidates)
    bvh_query_aabb_fast(
      &data.physics.static_bvh,
      bvh_entry.bounds,
      &static_candidates,
    )
    data.candidates_found += len(static_candidates)
    for entry_b in static_candidates {
      handle_b := entry_b.handle
      body_b := get(data.physics, handle_b) or_continue
      if body_a.trigger_only || body_b.trigger_only do continue
      bounding_spheres_intersect(
        body_a.cached_sphere_center,
        body_a.cached_sphere_radius,
        body_b.cached_sphere_center,
        body_b.cached_sphere_radius,
      ) or_continue
      data.narrow_phase_tests += 1
      point, normal, penetration, hit := test_collision(body_a, body_b)
      if !hit do continue
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
      if prev_contact, found := data.physics.prev_static_contacts[hash];
         found {
        contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
        contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
      }
      append(&data.static_contacts, contact)
    }
  }
}

// Dynamic collision detection task - pulls work atomically from shared queue
collision_detection_task_dynamic :: proc(task: thread.Task) {
  data := (^Collision_Detection_Task_Data_Dynamic)(task.data)
  task_start := time.now()
  defer data.elapsed_time = time.since(task_start)
  // Pre-allocate with capacity to avoid reallocations
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    0,
    128,
    context.temp_allocator,
  )
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    0,
    128,
    context.temp_allocator,
  )
  BATCH_SIZE :: 256
  for {
    start_idx := i32(
      sync.atomic_add(&data.work_queue.current_index, i32(BATCH_SIZE)),
    )
    if int(start_idx) >= data.work_queue.total_count do break
    end_idx := min(int(start_idx) + BATCH_SIZE, data.work_queue.total_count)
    #no_bounds_check for i in int(start_idx) ..< end_idx {
      bvh_entry := &data.physics.dynamic_bvh.primitives[i]
      handle_a := bvh_entry.handle
      body_a := get(data.physics, handle_a) or_continue
      if body_a.is_killed || body_a.is_sleeping do continue
      data.bodies_tested += 1
      // Query dynamic BVH for dynamic-dynamic collisions
      clear(&dyn_candidates)
      bvh_query_aabb_fast(
        &data.physics.dynamic_bvh,
        bvh_entry.bounds,
        &dyn_candidates,
      )
      data.candidates_found += len(dyn_candidates)
      for entry_b in dyn_candidates {
        handle_b := entry_b.handle
        if handle_a == handle_b do continue
        body_b := get(data.physics, handle_b) or_continue
        if handle_a.index > handle_b.index && !body_b.is_sleeping do continue
        if body_a.trigger_only || body_b.trigger_only do continue
        bounding_spheres_intersect(
          body_a.cached_sphere_center,
          body_a.cached_sphere_radius,
          body_b.cached_sphere_center,
          body_b.cached_sphere_radius,
        ) or_continue
        data.narrow_phase_tests += 1
        point, normal, penetration, hit := test_collision(body_a, body_b)
        if !hit do continue
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
        if prev_contact, found := data.physics.prev_dynamic_contacts[hash];
           found {
          contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
          contact.tangent_impulse =
            prev_contact.tangent_impulse * WARMSTART_COEF
        }
        append(&data.dynamic_contacts, contact)
      }
      // Query static BVH for dynamic-static collisions
      clear(&static_candidates)
      bvh_query_aabb_fast(
        &data.physics.static_bvh,
        bvh_entry.bounds,
        &static_candidates,
      )
      data.candidates_found += len(static_candidates)
      for entry_b in static_candidates {
        handle_b := entry_b.handle
        body_b := get(data.physics, handle_b) or_continue
        if body_a.trigger_only || body_b.trigger_only do continue
        bounding_spheres_intersect(
          body_a.cached_sphere_center,
          body_a.cached_sphere_radius,
          body_b.cached_sphere_center,
          body_b.cached_sphere_radius,
        ) or_continue
        data.narrow_phase_tests += 1
        point, normal, penetration, hit := test_collision(body_a, body_b)
        if !hit do continue
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
        if prev_contact, found := data.physics.prev_static_contacts[hash];
           found {
          contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
          contact.tangent_impulse =
            prev_contact.tangent_impulse * WARMSTART_COEF
        }
        append(&data.static_contacts, contact)
      }
    }
  }
}

parallel_collision_detection :: proc(
  self: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  parallel_start := time.now()
  primitive_count := len(self.dynamic_bvh.primitives)
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
      physics          = self,
      work_queue       = &work_queue,
      dynamic_contacts = make(
        [dynamic]DynamicContact,
        0,
        100,
        context.temp_allocator,
      ),
      static_contacts  = make(
        [dynamic]StaticContact,
        0,
        100,
        context.temp_allocator,
      ),
      thread_id        = i,
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
    for contact in task_data.dynamic_contacts {
      append(&self.dynamic_contacts, contact)
    }
    for contact in task_data.static_contacts {
      append(&self.static_contacts, contact)
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
  // Retest dynamic-dynamic contacts
  for pair_hash, prev_contact in physics.prev_dynamic_contacts {
    body_a := get(physics, prev_contact.body_a) or_continue
    body_b := get(physics, prev_contact.body_b) or_continue
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
    if body_a.trigger_only || body_b.trigger_only do continue
    point, normal, penetration := test_collision(body_a, body_b) or_continue
    if body_a.is_sleeping do wake_up(body_a)
    if body_b.is_sleeping do wake_up(body_b)
    contact := DynamicContact {
      body_a      = prev_contact.body_a,
      body_b      = prev_contact.body_b,
      point       = point,
      normal      = normal,
      penetration = penetration,
      restitution = (body_a.restitution + body_b.restitution) * 0.5,
      friction    = (body_a.friction + body_b.friction) * 0.5,
    }
    contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
    contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
    append(&physics.dynamic_contacts, contact)
    tested_pairs[pair_hash] = true
    persistent_tested += 1
  }
  // Retest dynamic-static contacts
  for pair_hash, prev_contact in physics.prev_static_contacts {
    body_a := get(physics, prev_contact.body_a) or_continue
    body_b := get(physics, prev_contact.body_b) or_continue
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
    if body_a.trigger_only || body_b.trigger_only do continue
    point, normal, penetration := test_collision(body_a, body_b) or_continue
    if body_a.is_sleeping do wake_up(body_a)
    contact := StaticContact {
      body_a      = prev_contact.body_a,
      body_b      = prev_contact.body_b,
      point       = point,
      normal      = normal,
      penetration = penetration,
      restitution = (body_a.restitution + body_b.restitution) * 0.5,
      friction    = (body_a.friction + body_b.friction) * 0.5,
    }
    contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
    contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
    append(&physics.static_contacts, contact)
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
  for contact in physics.dynamic_contacts {
    hash := collision_pair_hash(contact.body_a, contact.body_b)
    tested_pairs[hash] = true
  }
  for contact in physics.static_contacts {
    hash := collision_pair_hash(contact.body_a, contact.body_b)
    tested_pairs[hash] = true
  }
  // Pre-allocate with capacity to avoid reallocations
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    0,
    128,
    context.temp_allocator,
  )
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    0,
    128,
    context.temp_allocator,
  )
  test_collision_time: time.Duration
  test_collision_start := time.now()
  for &bvh_entry in physics.dynamic_bvh.primitives {
    handle_a := bvh_entry.handle
    body_a := get(physics, handle_a) or_continue
    if body_a.is_killed || body_a.is_sleeping do continue
    // Query dynamic BVH for dynamic-dynamic collisions
    clear(&dyn_candidates)
    bvh_query_aabb_fast(
      &physics.dynamic_bvh,
      bvh_entry.bounds,
      &dyn_candidates,
    )
    for entry_b in dyn_candidates {
      handle_b := entry_b.handle
      if handle_a == handle_b do continue
      pair_hash := collision_pair_hash(handle_a, handle_b)
      if tested_pairs[pair_hash] do continue
      body_b := get(physics, handle_b) or_continue
      if handle_a.index > handle_b.index && !body_b.is_sleeping do continue
      if body_a.trigger_only || body_b.trigger_only do continue
      if !bounding_spheres_intersect(body_a.cached_sphere_center, body_a.cached_sphere_radius, body_b.cached_sphere_center, body_b.cached_sphere_radius) do continue
      test_collision_start := time.now()
      point, normal, penetration, hit := test_collision(body_a, body_b)
      test_collision_time += time.since(test_collision_start)
      if !hit do continue
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
      if prev_contact, found := physics.prev_dynamic_contacts[hash]; found {
        contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
        contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
      }
      append(&physics.dynamic_contacts, contact)
    }
    // Query static BVH for dynamic-static collisions
    clear(&static_candidates)
    bvh_query_aabb_fast(
      &physics.static_bvh,
      bvh_entry.bounds,
      &static_candidates,
    )
    for entry_b in static_candidates {
      handle_b := entry_b.handle
      pair_hash := collision_pair_hash(handle_a, handle_b)
      if tested_pairs[pair_hash] do continue
      body_b := get(physics, handle_b) or_continue
      if body_a.trigger_only || body_b.trigger_only do continue
      if !bounding_spheres_intersect(body_a.cached_sphere_center, body_a.cached_sphere_radius, body_b.cached_sphere_center, body_b.cached_sphere_radius) do continue
      test_collision_start := time.now()
      point, normal, penetration, hit := test_collision(body_a, body_b)
      test_collision_time += time.since(test_collision_start)
      if !hit do continue
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
      if prev_contact, found := physics.prev_static_contacts[hash]; found {
        contact.normal_impulse = prev_contact.normal_impulse * WARMSTART_COEF
        contact.tangent_impulse = prev_contact.tangent_impulse * WARMSTART_COEF
      }
      append(&physics.static_contacts, contact)
    }
  }
  new_pairs :=
    len(physics.dynamic_contacts) +
    len(physics.static_contacts) -
    persistent_tested
  log.infof(
    "Test collision time: %.2fms | total time %.2fms | persistent=%d new=%d total=%d",
    time.duration_milliseconds(test_collision_time),
    time.duration_milliseconds(time.since(test_collision_start)),
    persistent_tested,
    new_pairs,
    len(physics.dynamic_contacts) + len(physics.static_contacts),
  )
}

ccd_task_dynamic :: proc(task: thread.Task) {
  data := (^CCD_Task_Data_Dynamic)(task.data)
  // Pre-allocate with capacity to avoid reallocations
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    0,
    64,
    context.temp_allocator,
  )
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    0,
    64,
    context.temp_allocator,
  )
  BATCH_SIZE :: 32
  for {
    start_idx := i32(
      sync.atomic_add(&data.work_queue.current_index, i32(BATCH_SIZE)),
    )
    if int(start_idx) >= data.work_queue.total_count do break
    end_idx := min(int(start_idx) + BATCH_SIZE, data.work_queue.total_count)
    #no_bounds_check for idx_a in int(start_idx) ..< end_idx {
      if idx_a >= len(data.physics.bodies.entries) do break
      entry_a := &data.physics.bodies.entries[idx_a]
      if !entry_a.active do continue
      body_a := &entry_a.item
      if body_a.is_killed || body_a.trigger_only || body_a.is_sleeping do continue
      collider_a := &body_a.collider
      velocity_mag_sq := linalg.length2(body_a.velocity)
      dt_sq := data.dt * data.dt
      min_extent := collider_min_extent(collider_a)
      threshold := min_extent * 0.5
      if velocity_mag_sq * dt_sq < threshold * threshold do continue
      data.bodies_tested += 1
      motion := body_a.velocity * data.dt
      earliest_toi := f32(1.0)
      earliest_normal := linalg.VECTOR3F32_Y_AXIS
      earliest_body_dyn: ^DynamicRigidBody = nil
      earliest_body_static: ^StaticRigidBody = nil
      has_ccd_hit := false
      current_aabb := body_a.cached_aabb
      swept_aabb: geometry.Aabb
      swept_aabb.min = linalg.min(
        body_a.cached_aabb.min,
        body_a.cached_aabb.min + motion,
      )
      swept_aabb.max = linalg.max(
        body_a.cached_aabb.max,
        body_a.cached_aabb.max + motion,
      )
      // Query dynamic BVH
      clear(&dyn_candidates)
      bvh_query_aabb_fast(
        &data.physics.dynamic_bvh,
        swept_aabb,
        &dyn_candidates,
      )
      data.total_candidates += len(dyn_candidates)
      for candidate in dyn_candidates {
        handle_b := candidate.handle
        if u32(idx_a) == handle_b.index do continue
        body_b := get(data.physics, handle_b) or_continue
        collider_b := &body_b.collider
        toi := swept_test(
          collider_a,
          collider_b,
          body_a.position,
          body_b.position,
          body_a.rotation,
          body_b.rotation,
          motion,
        )
        if toi.has_impact && toi.time < earliest_toi {
          earliest_toi = toi.time
          earliest_normal = toi.normal
          earliest_body_dyn = body_b
          earliest_body_static = nil
          has_ccd_hit = true
        }
      }
      // Query static BVH
      clear(&static_candidates)
      bvh_query_aabb_fast(
        &data.physics.static_bvh,
        swept_aabb,
        &static_candidates,
      )
      data.total_candidates += len(static_candidates)
      for candidate in static_candidates {
        handle_b := candidate.handle
        body_b := get(data.physics, handle_b) or_continue
        collider_b := &body_b.collider
        toi := swept_test(
          collider_a,
          collider_b,
          body_a.position,
          body_b.position,
          body_a.rotation,
          body_b.rotation,
          motion,
        )
        if toi.has_impact && toi.time < earliest_toi {
          earliest_toi = toi.time
          earliest_normal = toi.normal
          earliest_body_dyn = nil
          earliest_body_static = body_b
          has_ccd_hit = true
        }
      }
      if has_ccd_hit && earliest_toi > 0.01 && earliest_toi < 0.99 {
        safe_time := earliest_toi * 0.98
        body_a.position += body_a.velocity * data.dt * safe_time
        update_cached_aabb(body_a)
        vel_along_normal := linalg.dot(body_a.velocity, earliest_normal)
        if vel_along_normal < 0 {
          wake_up(body_a)
          if earliest_body_dyn != nil do wake_up(earliest_body_dyn)
          restitution := body_a.restitution
          friction := body_a.friction
          if earliest_body_dyn != nil {
            restitution =
              (body_a.restitution + earliest_body_dyn.restitution) * 0.5
            friction = (body_a.friction + earliest_body_dyn.friction) * 0.5
          } else if earliest_body_static != nil {
            restitution =
              (body_a.restitution + earliest_body_static.restitution) * 0.5
            friction = (body_a.friction + earliest_body_static.friction) * 0.5
          }
          body_a.velocity -=
            earliest_normal * vel_along_normal * (1.0 + restitution)
          tangent_vel :=
            body_a.velocity -
            earliest_normal * linalg.dot(body_a.velocity, earliest_normal)
          body_a.velocity -= tangent_vel * friction * 0.5
        }
        data.ccd_handled[idx_a] = true
      }
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
  // Pre-allocate with capacity to avoid reallocations
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    0,
    64,
    context.temp_allocator,
  )
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    0,
    64,
    context.temp_allocator,
  )
  #no_bounds_check for &entry_a, idx_a in physics.bodies.entries do if entry_a.active {
    body_a := &entry_a.item
    if body_a.is_killed || body_a.trigger_only || body_a.is_sleeping do continue
    velocity_mag_sq := linalg.length2(body_a.velocity)
    if velocity_mag_sq < CCD_THRESHOLD_SQ do continue
    bodies_tested += 1
    collider_a := &body_a.collider
    motion := body_a.velocity * dt
    earliest_toi := f32(1.0)
    earliest_normal := linalg.VECTOR3F32_Y_AXIS
    earliest_body_dyn: ^DynamicRigidBody = nil
    earliest_body_static: ^StaticRigidBody = nil
    has_ccd_hit := false
    swept_aabb: geometry.Aabb
    swept_aabb.min = linalg.min(body_a.cached_aabb.min, body_a.cached_aabb.min + motion)
    swept_aabb.max = linalg.max(body_a.cached_aabb.max, body_a.cached_aabb.max + motion)
    // Query dynamic BVH
    clear(&dyn_candidates)
    bvh_query_aabb_fast(&physics.dynamic_bvh, swept_aabb, &dyn_candidates)
    total_candidates += len(dyn_candidates)
    for candidate in dyn_candidates {
      handle_b := candidate.handle
      if u32(idx_a) == handle_b.index do continue
      body_b := get(physics, handle_b) or_continue
      collider_b := &body_b.collider
      toi := swept_test(collider_a, collider_b, body_a.position, body_b.position, body_a.rotation, body_b.rotation, motion)
      if toi.has_impact && toi.time < earliest_toi {
        earliest_toi = toi.time
        earliest_normal = toi.normal
        earliest_body_dyn = body_b
        earliest_body_static = nil
        has_ccd_hit = true
      }
    }
    // Query static BVH
    clear(&static_candidates)
    bvh_query_aabb_fast(&physics.static_bvh, swept_aabb, &static_candidates)
    total_candidates += len(static_candidates)
    for candidate in static_candidates {
      handle_b := candidate.handle
      body_b := get(physics, handle_b) or_continue
      collider_b := &body_b.collider
      toi := swept_test(collider_a, collider_b, body_a.position, body_b.position, body_a.rotation, body_b.rotation, motion)
      if toi.has_impact && toi.time < earliest_toi {
        earliest_toi = toi.time
        earliest_normal = toi.normal
        earliest_body_dyn = nil
        earliest_body_static = body_b
        has_ccd_hit = true
      }
    }
    if has_ccd_hit && earliest_toi > 0.01 && earliest_toi < 0.99 {
      safe_time := earliest_toi * 0.98
      body_a.position += body_a.velocity * dt * safe_time
      update_cached_aabb(body_a)
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
    }
  }
  return
}
