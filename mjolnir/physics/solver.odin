package physics

import cont "../containers"
import "base:intrinsics"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:mem"
import "core:sync"
import "core:thread"

// Split-impulse / pseudo-velocity stabilization.
// Velocity pass: only restitution feeds the velocity constraint (no positional energy injection).
// Position pass: Baumgarte penetration error is solved against per-body pseudo-velocities,
// which are applied to position once at integration time and then discarded.
BAUMGARTE_COEF :: 0.2
SLOP :: 0.002
RESTITUTION_THRESHOLD :: -1.0
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
  world:       ^World,
  thread_id:   int,
  num_threads: int,
  vel_iters:   int,
  pos_iters:   int,
  barrier:     ^SpinBarrier,
}

solver_worker_task :: proc(task: thread.Task) {
  data := (^SolverWorkerData)(task.data)
  world := data.world
  expected := i32(data.num_threads)
  local_sense := false
  contacts := world.dynamic_contacts[:]
  static_contacts := world.static_contacts[:]
  shard := world.solver_static_shards[data.thread_id][:]
  total_iters := data.vel_iters + data.pos_iters
  for iter in 0 ..< total_iters {
    is_position := iter >= data.vel_iters
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
        if is_position {
          #no_bounds_check for idx in bucket[s:e] {
            c := &contacts[idx]
            a := get(world, c.body_a) or_continue
            b := get(world, c.body_b) or_continue
            resolve_position_dynamic_dynamic(c, a, b)
          }
        } else {
          #no_bounds_check for idx in bucket[s:e] {
            c := &contacts[idx]
            a := get(world, c.body_a) or_continue
            b := get(world, c.body_b) or_continue
            resolve_velocity_dynamic_dynamic(c, a, b)
          }
        }
      }
      spin_barrier_wait(data.barrier, &local_sense, expected)
    }
    if is_position {
      #no_bounds_check for idx in shard {
        c := &static_contacts[idx]
        a := cont.get(world.bodies, c.body_a) or_continue
        b := cont.get(world.static_bodies, c.body_b) or_continue
        resolve_position_dynamic_static(c, a, b)
      }
    } else {
      #no_bounds_check for idx in shard {
        c := &static_contacts[idx]
        a := cont.get(world.bodies, c.body_a) or_continue
        b := cont.get(world.static_bodies, c.body_b) or_continue
        resolve_velocity_dynamic_static(c, a, b)
      }
    }
    spin_barrier_wait(data.barrier, &local_sense, expected)
  }
}

run_solver_iters :: proc(world: ^World, vel_iters, pos_iters, num_threads: int) {
  if (len(world.dynamic_contacts) + len(world.static_contacts)) < SOLVER_PARALLEL_THRESHOLD || num_threads <= 1 {
    for _ in 0 ..< vel_iters {
      solve_velocity_pass(world)
    }
    for _ in 0 ..< pos_iters {
      solve_position_pass(world)
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
      vel_iters   = vel_iters,
      pos_iters   = pos_iters,
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

clear_pseudo_velocities :: proc(world: ^World) {
  for i in 0 ..< len(world.bodies.entries) {
    if !world.bodies.entries[i].active do continue
    body := &world.bodies.entries[i].item
    body.pseudo_velocity = {}
    body.pseudo_angular_velocity = {}
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
  contact.position_bias = (BAUMGARTE_COEF / dt) * penetration_to_resolve
  contact.velocity_bias = 0
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  vel_b := body_b.velocity + linalg.cross(body_b.angular_velocity, contact.r_b)
  velocity_along_normal := linalg.dot(vel_b - vel_a, contact.normal)
  if velocity_along_normal < RESTITUTION_THRESHOLD {
    contact.velocity_bias = -contact.restitution * velocity_along_normal
  }
  contact.pseudo_normal_impulse = 0
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
  contact.position_bias = (BAUMGARTE_COEF / dt) * penetration_to_resolve
  contact.velocity_bias = 0
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  velocity_along_normal := linalg.dot(-vel_a, contact.normal)
  if velocity_along_normal < RESTITUTION_THRESHOLD {
    contact.velocity_bias = -contact.restitution * velocity_along_normal
  }
  contact.pseudo_normal_impulse = 0
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
  apply_impulse_at_point_no_wake(body_a, -impulse_n, contact.point)
  apply_impulse_at_point_no_wake(body_b, impulse_n, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  #unroll for i in 0 ..< 2 {
    impulse_t := tangents[i] * contact.tangent_impulse[i]
    apply_impulse_at_point_no_wake(body_a, -impulse_t, contact.point)
    apply_impulse_at_point_no_wake(body_b, impulse_t, contact.point)
  }
}

warmstart_contact_dynamic_static :: proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
) {
  impulse_n := contact.normal * contact.normal_impulse
  apply_impulse_at_point_no_wake(body_a, -impulse_n, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  #unroll for i in 0 ..< 2 {
    impulse_t := tangents[i] * contact.tangent_impulse[i]
    apply_impulse_at_point_no_wake(body_a, -impulse_t, contact.point)
  }
}

warmstart_contact :: proc {
  warmstart_contact_dynamic_dynamic,
  warmstart_contact_dynamic_static,
}

solve_velocity_pass :: proc(world: ^World) {
  for &c in world.dynamic_contacts {
    ba := get(world, c.body_a) or_continue
    bb := get(world, c.body_b) or_continue
    resolve_velocity_dynamic_dynamic(&c, ba, bb)
  }
  for &c in world.static_contacts {
    a := cont.get(world.bodies, c.body_a) or_continue
    b := cont.get(world.static_bodies, c.body_b) or_continue
    resolve_velocity_dynamic_static(&c, a, b)
  }
}

solve_position_pass :: proc(world: ^World) {
  for &c in world.dynamic_contacts {
    ba := get(world, c.body_a) or_continue
    bb := get(world, c.body_b) or_continue
    resolve_position_dynamic_dynamic(&c, ba, bb)
  }
  for &c in world.static_contacts {
    a := cont.get(world.bodies, c.body_a) or_continue
    b := cont.get(world.static_bodies, c.body_b) or_continue
    resolve_position_dynamic_static(&c, a, b)
  }
}

resolve_velocity_dynamic_dynamic :: #force_inline proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
) {
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  vel_b := body_b.velocity + linalg.cross(body_b.angular_velocity, contact.r_b)
  velocity_along_normal := linalg.dot(vel_b - vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal + contact.velocity_bias)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  impulse := contact.normal * (contact.normal_impulse - old_impulse)
  apply_impulse_at_point_no_wake(body_a, -impulse, contact.point)
  apply_impulse_at_point_no_wake(body_b, impulse, contact.point)
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
    apply_impulse_at_point_no_wake(body_a, -impulse_t, contact.point)
    apply_impulse_at_point_no_wake(body_b, impulse_t, contact.point)
  }
}

resolve_velocity_dynamic_static :: #force_inline proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
) {
  vel_a := body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
  velocity_along_normal := linalg.dot(-vel_a, contact.normal)
  delta_impulse := contact.normal_mass * (-velocity_along_normal + contact.velocity_bias)
  old_impulse := contact.normal_impulse
  contact.normal_impulse = max(old_impulse + delta_impulse, 0.0)
  impulse := contact.normal * (contact.normal_impulse - old_impulse)
  apply_impulse_at_point_no_wake(body_a, -impulse, contact.point)
  tangents := [2][3]f32{contact.tangent1, contact.tangent2}
  max_friction := contact.friction * contact.normal_impulse
  #unroll for i in 0 ..< 2 {
    vel_a = body_a.velocity + linalg.cross(body_a.angular_velocity, contact.r_a)
    velocity_along_tangent := linalg.dot(-vel_a, tangents[i])
    delta_impulse_t := contact.tangent_mass[i] * (-velocity_along_tangent)
    old_impulse_t := contact.tangent_impulse[i]
    contact.tangent_impulse[i] = clamp(old_impulse_t + delta_impulse_t, -max_friction, max_friction)
    impulse_t := tangents[i] * (contact.tangent_impulse[i] - old_impulse_t)
    apply_impulse_at_point_no_wake(body_a, -impulse_t, contact.point)
  }
}

// Pseudo-velocity solve. Operates on body.pseudo_{velocity,angular_velocity} only;
// these are integrated into position once and discarded, so they never feed back
// into real momentum (no Baumgarte energy injection).
resolve_position_dynamic_dynamic :: #force_inline proc(
  contact: ^DynamicContact,
  body_a: ^DynamicRigidBody,
  body_b: ^DynamicRigidBody,
) {
  if contact.position_bias <= 0 do return
  pvel_a := body_a.pseudo_velocity + linalg.cross(body_a.pseudo_angular_velocity, contact.r_a)
  pvel_b := body_b.pseudo_velocity + linalg.cross(body_b.pseudo_angular_velocity, contact.r_b)
  pseudo_vel_normal := linalg.dot(pvel_b - pvel_a, contact.normal)
  delta := contact.normal_mass * (contact.position_bias - pseudo_vel_normal)
  old := contact.pseudo_normal_impulse
  contact.pseudo_normal_impulse = max(old + delta, 0.0)
  applied := contact.pseudo_normal_impulse - old
  if applied == 0 do return
  impulse := contact.normal * applied
  body_a.pseudo_velocity -= impulse * body_a.inv_mass
  body_b.pseudo_velocity += impulse * body_b.inv_mass
  if body_a.enable_rotation {
    body_a.pseudo_angular_velocity -= body_a.inv_inertia * linalg.cross(contact.r_a, impulse)
  }
  if body_b.enable_rotation {
    body_b.pseudo_angular_velocity += body_b.inv_inertia * linalg.cross(contact.r_b, impulse)
  }
}

resolve_position_dynamic_static :: #force_inline proc(
  contact: ^StaticContact,
  body_a: ^DynamicRigidBody,
  body_b: ^StaticRigidBody,
) {
  if contact.position_bias <= 0 do return
  pvel_a := body_a.pseudo_velocity + linalg.cross(body_a.pseudo_angular_velocity, contact.r_a)
  pseudo_vel_normal := linalg.dot(-pvel_a, contact.normal)
  delta := contact.normal_mass * (contact.position_bias - pseudo_vel_normal)
  old := contact.pseudo_normal_impulse
  contact.pseudo_normal_impulse = max(old + delta, 0.0)
  applied := contact.pseudo_normal_impulse - old
  if applied == 0 do return
  impulse := contact.normal * applied
  body_a.pseudo_velocity -= impulse * body_a.inv_mass
  if body_a.enable_rotation {
    body_a.pseudo_angular_velocity -= body_a.inv_inertia * linalg.cross(contact.r_a, impulse)
  }
}

resolve_velocity :: proc {
  resolve_velocity_dynamic_dynamic,
  resolve_velocity_dynamic_static,
}

resolve_position :: proc {
  resolve_position_dynamic_dynamic,
  resolve_position_dynamic_static,
}

compute_tangent_basis :: proc(normal: [3]f32) -> ([3]f32, [3]f32) {
  tangent1 := linalg.orthogonal(normal)
  tangent2 := linalg.cross(normal, tangent1)
  return tangent1, tangent2
}
