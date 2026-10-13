#+private
package physics

import "../geometry"
import "base:intrinsics"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:mem"
import "core:sync"
import "core:thread"

// TGS-soft contact solver: collide once per frame, then per substep warm start,
// solve with soft bias, integrate, relax. Body A of a contact is always dynamic;
// body B may be static or kinematic (zero inverse mass, never written).

RESTITUTION_THRESHOLD :: 1.0 // m/s
CONTACT_HERTZ :: 30.0
CONTACT_DAMPING_RATIO :: 10.0
// Stiffer against infinite-mass bodies to resist push-through.
STATIC_HERTZ_SCALE :: 2.0
STATIC_DAMPING_SCALE :: 0.5
CONTACT_MAX_PUSH_SPEED :: 3.0 // m/s cap on penetration recovery
SOLVER_PARALLEL_THRESHOLD :: 200

Softness :: struct {
  bias_rate:     f32,
  mass_scale:    f32,
  impulse_scale: f32,
}

make_soft :: proc "contextless" (hertz, zeta, h: f32) -> Softness {
  if hertz <= 0 do return {0, 1, 0}
  omega := 2.0 * math.PI * hertz
  a1 := 2.0 * zeta + h * omega
  a2 := h * omega * a1
  a3 := 1.0 / (1.0 + a2)
  return {omega / a1, a2 * a3, a3}
}

// Softness for dynamic-dynamic [0] and dynamic-vs-infinite-mass [1] contacts
@(private = "file")
make_softness :: proc "contextless" (h: f32) -> [2]Softness {
  inv_h := h > 0 ? 1.0 / h : 0
  return {
    make_soft(min(CONTACT_HERTZ, 0.125 * inv_h), CONTACT_DAMPING_RATIO, h),
    make_soft(
      min(STATIC_HERTZ_SCALE * CONTACT_HERTZ, 0.25 * inv_h),
      STATIC_DAMPING_SCALE * CONTACT_DAMPING_RATIO,
      h,
    ),
  }
}

SpinBarrier :: struct {
  arrive: i32,
  sense:  bool,
}

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

// Static/kinematic bodies are never written by the solver, so only dynamic
// bodies take color bits.
build_solver_partition :: proc(world: ^World) {
  body_count := len(world.bodies.entries)
  resize(&world.solver_color_used, body_count)
  if body_count > 0 {
    mem.zero_slice(world.solver_color_used[:])
  }
  for &b in world.solver_color_buckets do clear(&b)
  clear(&world.solver_overflow)
  world.solver_color_count = 0
  for c, idx in world.contacts {
    a_idx := int(c.body_a.index)
    b_idx := int(c.body_b.index)
    used := world.solver_color_used[a_idx]
    if c.b_dynamic do used |= world.solver_color_used[b_idx]
    free_mask := ~used
    if free_mask == 0 {
      // No color left for this body pair: solve single-threaded instead of
      // racing on color 0.
      append(&world.solver_overflow, idx)
      continue
    }
    color := int(bits.trailing_zeros(free_mask))
    bit := u64(1) << u64(color)
    world.solver_color_used[a_idx] |= bit
    if c.b_dynamic do world.solver_color_used[b_idx] |= bit
    if color >= len(world.solver_color_buckets) {
      resize(&world.solver_color_buckets, color + 1)
    }
    append(&world.solver_color_buckets[color], idx)
    world.solver_color_count = max(world.solver_color_count, color + 1)
  }
}

// Inverse of the coupled 2x2 tangent effective-mass matrix at the manifold
// centroid. Coupling the two tangent directions keeps the friction cone
// circular — independent per-axis clamps inflate μ by up to √2 on diagonals.
@(private = "file")
invert_tangent_k :: #force_inline proc(k11, k12, k22: f32) -> matrix[2, 2]f32 {
  det := k11 * k22 - k12 * k12
  if math.abs(det) < math.F32_EPSILON do return {}
  inv_det := 1.0 / det
  return matrix[2, 2]f32{
    k22 * inv_det, -k12 * inv_det,
    -k12 * inv_det, k11 * inv_det,
  }
}

@(private = "file")
point_velocity :: #force_inline proc "contextless" (body: ^Body, r: [3]f32) -> [3]f32 {
  return body.velocity + linalg.cross(body.angular_velocity, r)
}

prepare_contact :: proc(contact: ^Contact, body_a, body_b: ^Body) {
  inv_mass_sum := body_a.inv_mass + body_b.inv_mass
  centroid: [3]f32
  for i in 0 ..< contact.count {
    p := &contact.points[i]
    centroid += p.point
    p.r_a = p.point - body_a.position
    p.r_b = p.point - body_b.position
    rn_a := linalg.cross(p.r_a, contact.normal)
    rn_b := linalg.cross(p.r_b, contact.normal)
    normal_mass :=
      inv_mass_sum +
      linalg.dot(body_a.inv_inertia_world * rn_a, rn_a) +
      linalg.dot(body_b.inv_inertia_world * rn_b, rn_b)
    rel := point_velocity(body_b, p.r_b) - point_velocity(body_a, p.r_a)
    p.normal_mass = normal_mass > math.F32_EPSILON ? 1.0 / normal_mass : 0
    p.relative_velocity = linalg.dot(rel, contact.normal)
    p.max_normal_impulse = 0
  }
  centroid /= f32(contact.count)
  contact.r_a_c = centroid - body_a.position
  contact.r_b_c = centroid - body_b.position
  contact.tangent1, contact.tangent2 = geometry.tangent_basis(contact.normal)
  rt_a1 := linalg.cross(contact.r_a_c, contact.tangent1)
  rt_a2 := linalg.cross(contact.r_a_c, contact.tangent2)
  rt_b1 := linalg.cross(contact.r_b_c, contact.tangent1)
  rt_b2 := linalg.cross(contact.r_b_c, contact.tangent2)
  ia1 := body_a.inv_inertia_world * rt_a1
  ia2 := body_a.inv_inertia_world * rt_a2
  ib1 := body_b.inv_inertia_world * rt_b1
  ib2 := body_b.inv_inertia_world * rt_b2
  k11 := inv_mass_sum + linalg.dot(ia1, rt_a1) + linalg.dot(ib1, rt_b1)
  k12 := linalg.dot(ia1, rt_a2) + linalg.dot(ib1, rt_b2)
  k22 := inv_mass_sum + linalg.dot(ia2, rt_a2) + linalg.dot(ib2, rt_b2)
  n := contact.normal
  kt := linalg.dot(n, body_a.inv_inertia_world * n) + linalg.dot(n, body_b.inv_inertia_world * n)
  contact.tangent_mass = invert_tangent_k(k11, k12, k22)
  contact.twist_mass = kt > math.F32_EPSILON ? 1.0 / kt : 0
}

prepare_contacts :: proc(world: ^World) {
  parallel_for(world, len(world.contacts), nil, proc(world: ^World, _: rawptr, _, start, end: int) {
    #no_bounds_check for i in start ..< end {
      c := &world.contacts[i]
      a := get_body(world, c.body_a) or_continue
      b := get_body(world, c.body_b) or_continue
      prepare_contact(c, a, b)
    }
  }, min_items = 200)
}

@(private = "file")
apply_pair_impulse :: #force_inline proc(a, b: ^Body, impulse, point: [3]f32) {
  apply_impulse_at_point(a, -impulse, point)
  apply_impulse_at_point(b, impulse, point)
}

@(private = "file")
apply_pair_twist :: #force_inline proc(a, b: ^Body, twist: [3]f32) {
  apply_angular_impulse(a, -twist)
  apply_angular_impulse(b, twist)
}

warmstart_contact :: proc(contact: ^Contact, body_a, body_b: ^Body) {
  for i in 0 ..< contact.count {
    p := &contact.points[i]
    apply_pair_impulse(body_a, body_b, contact.normal * p.normal_impulse, p.point)
  }
  impulse_t := contact.tangent1 * contact.tangent_impulse[0] +
    contact.tangent2 * contact.tangent_impulse[1]
  apply_pair_impulse(body_a, body_b, impulse_t, body_a.position + contact.r_a_c)
  apply_pair_twist(body_a, body_b, contact.normal * contact.twist_impulse)
}

// Current separation: base + how much the anchors moved along the normal
// since prepare (translation-only approximation of box3d's delta tracking).
@(private = "file")
current_separation :: #force_inline proc(
  p: ^ContactPoint,
  normal: [3]f32,
  body_a, body_b: ^Body,
) -> f32 {
  ds := (body_b.position - body_b.position0) - (body_a.position - body_a.position0)
  return p.base_separation + linalg.dot(ds, normal)
}

resolve_velocity :: proc(
  contact: ^Contact,
  body_a, body_b: ^Body,
  soft: Softness,
  inv_h: f32,
  use_bias: bool,
) {
  total_normal_impulse: f32 = 0
  lever_sum: f32 = 0
  centroid := body_a.position + contact.r_a_c
  for i in 0 ..< contact.count {
    p := &contact.points[i]
    s := current_separation(p, contact.normal, body_a, body_b)
    bias: f32 = 0
    mass_scale: f32 = 1
    impulse_scale: f32 = 0
    if s > 0 {
      // Speculative: only stop the approach, never pull
      bias = s * inv_h
    } else if use_bias {
      bias = max(soft.bias_rate * s, -CONTACT_MAX_PUSH_SPEED)
      mass_scale = soft.mass_scale
      impulse_scale = soft.impulse_scale
    }
    vn := linalg.dot(point_velocity(body_b, p.r_b) - point_velocity(body_a, p.r_a), contact.normal)
    delta_impulse := -p.normal_mass * mass_scale * (vn + bias) - impulse_scale * p.normal_impulse
    old_impulse := p.normal_impulse
    p.normal_impulse = max(old_impulse + delta_impulse, 0.0)
    p.max_normal_impulse = max(p.max_normal_impulse, p.normal_impulse)
    apply_pair_impulse(body_a, body_b, contact.normal * (p.normal_impulse - old_impulse), p.point)
    total_normal_impulse += p.normal_impulse
    lever_sum += p.normal_impulse * linalg.length(p.point - centroid)
  }
  rel := point_velocity(body_b, contact.r_b_c) - point_velocity(body_a, contact.r_a_c)
  vt := [2]f32{linalg.dot(rel, contact.tangent1), linalg.dot(rel, contact.tangent2)}
  old_t := contact.tangent_impulse
  new_t := old_t + contact.tangent_mass * -vt
  max_friction := contact.friction * total_normal_impulse
  len_t := linalg.length(new_t)
  if len_t > max_friction {
    new_t *= max_friction / max(len_t, math.F32_EPSILON)
  }
  contact.tangent_impulse = new_t
  applied_t := new_t - old_t
  apply_pair_impulse(body_a, body_b, contact.tangent1 * applied_t[0] + contact.tangent2 * applied_t[1], centroid)
  // Twist friction about the normal — resists spinning even on flat rest.
  // Torque budget comes from the normal impulses' lever arms.
  wt := linalg.dot(body_b.angular_velocity - body_a.angular_velocity, contact.normal)
  max_twist := contact.friction * lever_sum
  old_w := contact.twist_impulse
  contact.twist_impulse = clamp(old_w - contact.twist_mass * wt, -max_twist, max_twist)
  apply_pair_twist(body_a, body_b, contact.normal * (contact.twist_impulse - old_w))
}

// Applied separately so the soft bias never doubles as bounce, and gated on
// max_normal_impulse so speculative points that never touched don't bounce.
apply_restitution :: proc(contact: ^Contact, body_a, body_b: ^Body) {
  if contact.restitution == 0 do return
  for i in 0 ..< contact.count {
    p := &contact.points[i]
    if p.relative_velocity > -RESTITUTION_THRESHOLD || p.max_normal_impulse == 0 do continue
    vn := linalg.dot(point_velocity(body_b, p.r_b) - point_velocity(body_a, p.r_a), contact.normal)
    delta_impulse := -p.normal_mass * (vn + contact.restitution * p.relative_velocity)
    old_impulse := p.normal_impulse
    p.normal_impulse = max(old_impulse + delta_impulse, 0.0)
    apply_pair_impulse(body_a, body_b, contact.normal * (p.normal_impulse - old_impulse), p.point)
  }
}

@(private = "file")
SolverPass :: enum {
  Warmstart,
  Bias,
  Relax,
  Restitution,
}

@(private = "file")
solve_contact :: #force_inline proc(
  world: ^World,
  c: ^Contact,
  pass: SolverPass,
  soft: [2]Softness,
  inv_h: f32,
) {
  a, a_ok := get_body(world, c.body_a)
  b, b_ok := get_body(world, c.body_b)
  if !a_ok || !b_ok do return
  switch pass {
  case .Warmstart:
    warmstart_contact(c, a, b)
  case .Bias:
    resolve_velocity(c, a, b, soft[c.b_dynamic ? 0 : 1], inv_h, true)
  case .Relax:
    resolve_velocity(c, a, b, soft[c.b_dynamic ? 0 : 1], inv_h, false)
  case .Restitution:
    apply_restitution(c, a, b)
  }
}

@(private = "file")
run_pass :: proc(
  world: ^World,
  indices: []int,
  pass: SolverPass,
  soft: [2]Softness,
  inv_h: f32,
) {
  #no_bounds_check for idx in indices {
    solve_contact(world, &world.contacts[idx], pass, soft, inv_h)
  }
}

@(private = "file")
SolverWorkerData :: struct {
  world:        ^World,
  thread_id:    int,
  num_threads:  int,
  num_substeps: int,
  h:            f32,
  ccd_handled:  []bool,
  barrier:      ^SpinBarrier,
}

@(private = "file")
worker_contact_phase :: proc(
  data: ^SolverWorkerData,
  pass: SolverPass,
  soft: [2]Softness,
  inv_h: f32,
  local_sense: ^bool,
) {
  world := data.world
  if data.num_threads == 1 {
    #no_bounds_check for &c in world.contacts {
      solve_contact(world, &c, pass, soft, inv_h)
    }
    return
  }
  expected := i32(data.num_threads)
  for color_idx in 0 ..< world.solver_color_count {
    bucket := world.solver_color_buckets[color_idx][:]
    chunk := (len(bucket) + data.num_threads - 1) / data.num_threads
    s := min(data.thread_id * chunk, len(bucket))
    e := min(s + chunk, len(bucket))
    if s < e do run_pass(world, bucket[s:e], pass, soft, inv_h)
    spin_barrier_wait(data.barrier, local_sense, expected)
  }
  // Overflow contacts share bodies with every color; single thread only.
  if data.thread_id == 0 {
    run_pass(world, world.solver_overflow[:], pass, soft, inv_h)
  }
  spin_barrier_wait(data.barrier, local_sense, expected)
}

@(private = "file")
solver_worker :: proc(data: ^SolverWorkerData) {
  world := data.world
  local_sense := false
  inv_h := data.h > 0 ? 1.0 / data.h : 0
  soft := make_softness(data.h)
  body_count := len(world.awake_list)
  chunk := (body_count + data.num_threads - 1) / data.num_threads
  b_start := min(data.thread_id * chunk, body_count)
  b_end := min(b_start + chunk, body_count)
  sync_bodies :: proc(data: ^SolverWorkerData, local_sense: ^bool) {
    if data.num_threads > 1 do spin_barrier_wait(data.barrier, local_sense, i32(data.num_threads))
  }
  for _ in 0 ..< data.num_substeps {
    integrate_velocities_range(world, b_start, b_end, data.h)
    sync_bodies(data, &local_sense)
    worker_contact_phase(data, .Warmstart, soft, inv_h, &local_sense)
    worker_contact_phase(data, .Bias, soft, inv_h, &local_sense)
    integrate_positions_range(world, b_start, b_end, data.h, data.ccd_handled)
    sync_bodies(data, &local_sense)
    worker_contact_phase(data, .Relax, soft, inv_h, &local_sense)
  }
  worker_contact_phase(data, .Restitution, soft, inv_h, &local_sense)
}

run_substep_loop :: proc(world: ^World, h: f32, num_substeps: int, ccd_handled: []bool) {
  num_threads := world.thread_count
  if len(world.contacts) < SOLVER_PARALLEL_THRESHOLD do num_threads = 1
  barrier := SpinBarrier{}
  task_data := make([]SolverWorkerData, num_threads, context.temp_allocator)
  for t in 0 ..< num_threads {
    task_data[t] = SolverWorkerData {
      world        = world,
      thread_id    = t,
      num_threads  = num_threads,
      num_substeps = num_substeps,
      h            = h,
      ccd_handled  = ccd_handled,
      barrier      = &barrier,
    }
  }
  if num_threads == 1 {
    solver_worker(&task_data[0])
    return
  }
  build_solver_partition(world)
  for t in 0 ..< num_threads {
    thread.pool_add_task(&world.thread_pool, mem.nil_allocator(), proc(task: thread.Task) {
      solver_worker((^SolverWorkerData)(task.data))
    }, &task_data[t], t)
  }
  pool_wait(&world.thread_pool)
}
