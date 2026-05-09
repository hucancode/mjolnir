package physics

import cont "../containers"
import "base:intrinsics"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:mem"
import "core:sync"
import "core:thread"

BAUMGARTE_COEF :: 0.4
SLOP :: 0.002
RESTITUTION_THRESHOLD :: -0.5
WARMSTART_COEF :: 0.8
SOLVER_PARALLEL_THRESHOLD :: 200

SpinBarrier :: struct {
  arrive: i32,
  sense:  bool,
}

@(private)
spin_barrier_wait :: proc "contextless" (b: ^SpinBarrier, local_sense: ^bool, expected: i32) {
  local_sense^ = !local_sense^
  cur := sync.atomic_add(&b.arrive, 1) + 1
  if cur == expected {
    sync.atomic_store(&b.arrive, 0)
    sync.atomic_store(&b.sense, local_sense^)
    return
  }
  for sync.atomic_load(&b.sense) != local_sense^ {
    intrinsics.cpu_relax()
  }
}

SolverWorkerData :: struct {
  world:        ^World,
  thread_id:    int,
  num_threads:  int,
  total_iters:  int,
  bias_iters:   int,
  barrier:      ^SpinBarrier,
}

solver_worker_task :: proc(task: thread.Task) {
  data := (^SolverWorkerData)(task.data)
  world := data.world
  expected := i32(data.num_threads)
  local_sense := false
  contacts := world.dynamic_contacts[:]
  static_contacts := world.static_contacts[:]
  shard := world.solver_static_shards[data.thread_id][:]
  for iter in 0 ..< data.total_iters {
    use_bias := iter < data.bias_iters
    for color_idx in 0 ..< world.solver_color_count {
      bucket := world.solver_color_buckets[color_idx][:]
      bucket_len := len(bucket)
      if bucket_len == 0 {
        spin_barrier_wait(data.barrier, &local_sense, expected)
        continue
      }
      chunk := (bucket_len + data.num_threads - 1) / data.num_threads
      s := data.thread_id * chunk
      e := min(s + chunk, bucket_len)
      if s < e {
        for idx in bucket[s:e] {
          c := &contacts[idx]
          a := get(world, c.body_a) or_continue
          b := get(world, c.body_b) or_continue
          resolve_contact_dynamic_dynamic(c, a, b, use_bias)
        }
      }
      spin_barrier_wait(data.barrier, &local_sense, expected)
    }
    for idx in shard {
      c := &static_contacts[idx]
      a := cont.get(world.bodies, c.body_a) or_continue
      b := cont.get(world.static_bodies, c.body_b) or_continue
      resolve_contact_dynamic_static(c, a, b, use_bias)
    }
    spin_barrier_wait(data.barrier, &local_sense, expected)
  }
}

run_solver_iters :: proc(world: ^World, total_iters, bias_iters, num_threads: int) {
  if (len(world.dynamic_contacts) + len(world.static_contacts)) < SOLVER_PARALLEL_THRESHOLD || num_threads <= 1 {
    for iter in 0 ..< total_iters {
      use_bias := iter < bias_iters
      solve_dynamic_pass(world, use_bias)
      for &c in world.static_contacts {
        a := cont.get(world.bodies, c.body_a) or_continue
        b := cont.get(world.static_bodies, c.body_b) or_continue
        resolve_contact_dynamic_static(&c, a, b, use_bias)
      }
    }
    return
  }
  barrier := SpinBarrier{}
  task_data := make([]SolverWorkerData, num_threads, context.temp_allocator)
  for t in 0 ..< num_threads {
    task_data[t] = SolverWorkerData{
      world       = world,
      thread_id   = t,
      num_threads = num_threads,
      total_iters = total_iters,
      bias_iters  = bias_iters,
      barrier     = &barrier,
    }
    thread.pool_add_task(&world.thread_pool, mem.nil_allocator(), solver_worker_task, &task_data[t], t)
  }
  pool_wait(&world.thread_pool)
}

build_solver_partition :: proc(world: ^World, num_shards: int) {
  body_count := len(world.bodies.entries)
  resize(&world.solver_color_used, body_count)
  if body_count > 0 {
    mem.zero_slice(world.solver_color_used[:])
  }
  for &b in world.solver_color_buckets do clear(&b)
  world.solver_color_count = 0
  for c, idx in world.dynamic_contacts {
    a_idx := int(c.body_a.index)
    b_idx := int(c.body_b.index)
    if a_idx >= body_count || b_idx >= body_count do continue
    used := world.solver_color_used[a_idx] | world.solver_color_used[b_idx]
    free_mask := ~used
    color := 0
    if free_mask != 0 {
      color = int(bits.trailing_zeros(free_mask))
    }
    if color >= 64 do color = 0
    bit := u64(1) << u64(color)
    world.solver_color_used[a_idx] |= bit
    world.solver_color_used[b_idx] |= bit
    if color >= len(world.solver_color_buckets) {
      old_len := len(world.solver_color_buckets)
      resize(&world.solver_color_buckets, color + 1)
      for i in old_len ..< color + 1 {
        world.solver_color_buckets[i] = make([dynamic]int)
      }
    }
    append(&world.solver_color_buckets[color], idx)
    if color + 1 > world.solver_color_count {
      world.solver_color_count = color + 1
    }
  }
  shard_count := max(1, num_shards)
  if shard_count != world.solver_static_shard_count {
    for &s in world.solver_static_shards do delete(s)
    delete(world.solver_static_shards)
    world.solver_static_shards = make([][dynamic]int, shard_count)
    for i in 0 ..< shard_count {
      world.solver_static_shards[i] = make([dynamic]int)
    }
    world.solver_static_shard_count = shard_count
  } else {
    for i in 0 ..< shard_count do clear(&world.solver_static_shards[i])
  }
  for c, idx in world.static_contacts {
    s := int(c.body_a.index) % shard_count
    append(&world.solver_static_shards[s], idx)
  }
}

prepare_contact_dynamic_dynamic :: proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
  dt: f32,
) {
  contact.r_a = contact.point - body_a.position
  contact.r_b = contact.point - body_b.position
  r_a_cross_n := linalg.cross(contact.r_a, contact.normal)
  r_b_cross_n := linalg.cross(contact.r_b, contact.normal)
  inv_mass_sum := body_a.inv_mass + body_b.inv_mass
  angular_factor_a := linalg.dot(body_a.inv_inertia * r_a_cross_n, r_a_cross_n)
  angular_factor_b := linalg.dot(body_b.inv_inertia * r_b_cross_n, r_b_cross_n)
  normal_mass := inv_mass_sum + angular_factor_a + angular_factor_b
  if normal_mass > math.F32_EPSILON {
    contact.normal_mass = 1.0 / normal_mass
  } else {
    contact.normal_mass = 0
  }
  contact.tangent1, contact.tangent2 = compute_tangent_basis(contact.normal)
  #unroll for i in 0 ..< 2 {
    tangent := i == 0 ? contact.tangent1 : contact.tangent2
    r_a_cross_t := linalg.cross(contact.r_a, tangent)
    r_b_cross_t := linalg.cross(contact.r_b, tangent)
    angular_factor_a_t := linalg.dot(body_a.inv_inertia * r_a_cross_t, r_a_cross_t)
    angular_factor_b_t := linalg.dot(body_b.inv_inertia * r_b_cross_t, r_b_cross_t)
    tangent_mass := inv_mass_sum + angular_factor_a_t + angular_factor_b_t
    if tangent_mass > math.F32_EPSILON {
      contact.tangent_mass[i] = 1.0 / tangent_mass
    } else {
      contact.tangent_mass[i] = 0
    }
  }
  penetration_to_resolve := max(contact.penetration - SLOP, 0.0)
  contact.bias = (BAUMGARTE_COEF / dt) * penetration_to_resolve
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  vel_b := body_b.velocity + linalg.cross(body_b.angular_velocity, contact.r_b)
  relative_velocity := vel_b - vel_a
  velocity_along_normal := linalg.dot(relative_velocity, contact.normal)
  if velocity_along_normal < RESTITUTION_THRESHOLD {
    contact.bias += -contact.restitution * velocity_along_normal
  }
}

prepare_contact_dynamic_static :: proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
  dt: f32,
) {
  contact.r_a = contact.point - body_a.position
  r_a_cross_n := linalg.cross(contact.r_a, contact.normal)
  inv_mass_sum := body_a.inv_mass
  angular_factor_a := linalg.dot(body_a.inv_inertia * r_a_cross_n, r_a_cross_n)
  normal_mass := inv_mass_sum + angular_factor_a
  if normal_mass > math.F32_EPSILON {
    contact.normal_mass = 1.0 / normal_mass
  } else {
    contact.normal_mass = 0
  }
  contact.tangent1, contact.tangent2 = compute_tangent_basis(contact.normal)
  #unroll for i in 0 ..< 2 {
    tangent := i == 0 ? contact.tangent1 : contact.tangent2
    r_a_cross_t := linalg.cross(contact.r_a, tangent)
    angular_factor_a_t := linalg.dot(body_a.inv_inertia * r_a_cross_t, r_a_cross_t)
    tangent_mass := inv_mass_sum + angular_factor_a_t
    if tangent_mass > math.F32_EPSILON {
      contact.tangent_mass[i] = 1.0 / tangent_mass
    } else {
      contact.tangent_mass[i] = 0
    }
  }
  penetration_to_resolve := max(contact.penetration - SLOP, 0.0)
  contact.bias = (BAUMGARTE_COEF / dt) * penetration_to_resolve
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  relative_velocity := -vel_a
  velocity_along_normal := linalg.dot(relative_velocity, contact.normal)
  if velocity_along_normal < RESTITUTION_THRESHOLD {
    contact.bias += -contact.restitution * velocity_along_normal
  }
}

prepare_contact :: proc {
  prepare_contact_dynamic_dynamic,
  prepare_contact_dynamic_static,
}

warmstart_contact_dynamic_dynamic :: proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
) {
  impulse_n := contact.normal * contact.normal_impulse
  apply_impulse_at_point(body_a, -impulse_n, contact.point)
  apply_impulse_at_point(body_b, impulse_n, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  #unroll for i in 0 ..< 2 {
    impulse_t := tangents[i] * contact.tangent_impulse[i]
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
    apply_impulse_at_point(body_b, impulse_t, contact.point)
  }
}

warmstart_contact_dynamic_static :: proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
) {
  impulse_n := contact.normal * contact.normal_impulse
  apply_impulse_at_point(body_a, -impulse_n, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  #unroll for i in 0 ..< 2 {
    impulse_t := tangents[i] * contact.tangent_impulse[i]
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
  }
}

warmstart_contact :: proc {
  warmstart_contact_dynamic_dynamic,
  warmstart_contact_dynamic_static,
}

solve_dynamic_pass :: proc(world: ^World, use_bias: bool) {
  for &c in world.dynamic_contacts {
    ba := get(world, c.body_a) or_continue
    bb := get(world, c.body_b) or_continue
    resolve_contact_dynamic_dynamic(&c, ba, bb, use_bias)
  }
}

resolve_contact_dynamic_dynamic :: #force_inline proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
  use_bias: bool,
) {
  bias := use_bias ? contact.bias : 0
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  vel_b := body_b.velocity + linalg.cross(body_b.angular_velocity, contact.r_b)
  velocity_along_normal := linalg.dot(vel_b - vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal + bias)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  impulse := contact.normal * (contact.normal_impulse - old_impulse)
  apply_impulse_at_point(body_a, -impulse, contact.point)
  apply_impulse_at_point(body_b, impulse, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  max_friction := contact.friction * contact.normal_impulse
  #unroll for i in 0 ..< 2 {
    vel_a = body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
    vel_b = body_b.velocity + linalg.cross(body_b.angular_velocity, contact.r_b)
    velocity_along_tangent := linalg.dot(vel_b - vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
    apply_impulse_at_point(body_b, impulse_t, contact.point)
  }
}

resolve_contact_dynamic_static :: #force_inline proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
  use_bias: bool,
) {
  bias := use_bias ? contact.bias : 0
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  velocity_along_normal := linalg.dot(-vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal + bias)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  impulse := contact.normal * (contact.normal_impulse - old_impulse)
  apply_impulse_at_point(body_a, -impulse, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  max_friction := contact.friction * contact.normal_impulse
  #unroll for i in 0 ..< 2 {
    vel_a = body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
    velocity_along_tangent := linalg.dot(-vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    apply_impulse_at_point(body_a, -impulse_t, contact.point)
  }
}

resolve_contact :: proc {
  resolve_contact_dynamic_dynamic,
  resolve_contact_dynamic_static,
}

compute_tangent_basis :: proc(normal: [3]f32) -> ([3]f32, [3]f32) {
  tangent1 := linalg.orthogonal(normal)
  tangent2 := linalg.cross(normal, tangent1)
  return tangent1, tangent2
}
