package physics

import cont "../containers"
import "../geometry"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_THREAD_COUNT :: 16
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
  physics:  ^World,
  start:    int,
  end:      int,
  contacts: [dynamic]Contact,
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
    body := cont.get(data.physics.bodies, bvh_entry.handle) or_continue
    bvh_entry.bounds = body.cached_aabb
  }
}

parallel_bvh_refit :: proc(
  physics: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  primitive_count := len(physics.spatial_index.primitives)
  if primitive_count == 0 do return
  if primitive_count < 100 ||
     num_threads == 1 ||
     !physics.thread_pool_running {
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
  thread.pool_finish(&physics.thread_pool)
  geometry.bvh_refit(&physics.spatial_index)
}

sequential_bvh_refit :: proc(physics: ^World) {
  for &bvh_entry in physics.spatial_index.primitives {
    body := cont.get(physics.bodies, bvh_entry.handle) or_continue
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
    collider := cont.get(
      data.physics.colliders,
      body.collider_handle,
    ) or_continue
    update_cached_aabb(body, collider)
  }
}

parallel_update_aabb_cache :: proc(
  physics: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  body_count := len(physics.bodies.entries)
  if body_count == 0 do return
  if body_count < 100 || num_threads == 1 || !physics.thread_pool_running {
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
  thread.pool_finish(&physics.thread_pool)
}

sequential_update_aabb_cache :: proc(physics: ^World) {
  for &entry in physics.bodies.entries do if entry.active {
    body := &entry.item
    if body.is_sleeping do continue
    collider := cont.get(physics.colliders, body.collider_handle) or_continue
    update_cached_aabb(body, collider)
  }
}

collision_detection_task :: proc(task: thread.Task) {
  data := (^Collision_Detection_Task_Data)(task.data)
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  for i in data.start ..< data.end {
    bvh_entry := &data.physics.spatial_index.primitives[i]
    handle_a := bvh_entry.handle
    body_a := cont.get(data.physics.bodies, handle_a) or_continue
    // Skip query for static or sleeping bodies (they don't initiate collisions)
    if body_a.is_static || body_a.is_sleeping do continue
    clear(&candidates)
    bvh_query_aabb_fast(
      &data.physics.spatial_index,
      bvh_entry.bounds,
      &candidates,
    )
    for entry_b in candidates {
      handle_b := entry_b.handle
      if handle_a == handle_b do continue
      body_b := cont.get(data.physics.bodies, handle_b) or_continue
      if handle_a.index > handle_b.index && !body_b.is_static && !body_b.is_sleeping do continue
      if body_a.is_static && body_b.is_static do continue
      if body_a.trigger_only || body_b.trigger_only do continue
      collider_a := cont.get(
        data.physics.colliders,
        body_a.collider_handle,
      ) or_continue
      collider_b := cont.get(
        data.physics.colliders,
        body_b.collider_handle,
      ) or_continue
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

parallel_collision_detection :: proc(
  physics: ^World,
  num_threads := DEFAULT_THREAD_COUNT,
) {
  primitive_count := len(physics.spatial_index.primitives)
  if primitive_count == 0 do return
  if primitive_count < 100 ||
     num_threads == 1 ||
     !physics.thread_pool_running {
    sequential_collision_detection(physics)
    return
  }
  chunk_size := (primitive_count + num_threads - 1) / num_threads
  task_data_array := make(
    []Collision_Detection_Task_Data,
    num_threads,
    context.temp_allocator,
  )
  for i in 0 ..< num_threads {
    start := i * chunk_size
    end := min(start + chunk_size, primitive_count)
    if start >= primitive_count do break
    task_data_array[i] = Collision_Detection_Task_Data {
      physics  = physics,
      start    = start,
      end      = end,
      contacts = make([dynamic]Contact, 0, 100, context.temp_allocator),
    }
    thread.pool_add_task(
      &physics.thread_pool,
      mem.nil_allocator(),
      collision_detection_task,
      &task_data_array[i],
      i,
    )
  }
  thread.pool_finish(&physics.thread_pool)
  for &task_data in task_data_array {
    for contact in task_data.contacts {
      append(&physics.contacts, contact)
    }
  }
}

sequential_collision_detection :: proc(physics: ^World) {
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  test_collision_time: time.Duration
  test_collision_start := time.now()
  for &bvh_entry in physics.spatial_index.primitives {
    handle_a := bvh_entry.handle
    body_a := cont.get(physics.bodies, handle_a) or_continue
    // Skip query for static or sleeping bodies
    if body_a.is_static || body_a.is_sleeping do continue
    clear(&candidates)
    bvh_query_aabb_fast(&physics.spatial_index, bvh_entry.bounds, &candidates)
    for entry_b in candidates {
      handle_b := entry_b.handle
      if handle_a == handle_b do continue
      body_b := cont.get(physics.bodies, handle_b) or_continue
      if handle_a.index > handle_b.index && !body_b.is_static && !body_b.is_sleeping do continue
      if body_a.is_static && body_b.is_static do continue
      if body_a.trigger_only || body_b.trigger_only do continue
      collider_a := cont.get(
        physics.colliders,
        body_a.collider_handle,
      ) or_continue
      collider_b := cont.get(
        physics.colliders,
        body_b.collider_handle,
      ) or_continue
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
  log.infof(
    "Test collision time: %.2fms | total time %.2fms",
    time.duration_milliseconds(test_collision_time),
    time.duration_milliseconds(time.since(test_collision_start)),
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
    collider_a := cont.get(
      data.physics.colliders,
      body_a.collider_handle,
    ) or_continue
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
      body_b := cont.get(data.physics.bodies, handle_b) or_continue
      collider_b := cont.get(
        data.physics.colliders,
        body_b.collider_handle,
      ) or_continue
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
  if body_count < 100 || num_threads == 1 || !physics.thread_pool_running {
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
  thread.pool_finish(&physics.thread_pool)
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
    collider_a := cont.get(physics.colliders, body_a.collider_handle) or_continue
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
      body_b := cont.get(physics.bodies, handle_b) or_continue
      collider_b := cont.get(physics.colliders, body_b.collider_handle) or_continue
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
