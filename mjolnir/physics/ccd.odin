#+private
package physics

import "../containers"
import "../geometry"
import "core:math"
import "core:math/linalg"

// Sweeps return the time of impact t in [0, 1] as a fraction of the motion.

@(private)
swept_sphere_sphere :: proc(
  pos_a, pos_b: [3]f32,
  radius_a, radius_b: f32,
  velocity_a: [3]f32,
) -> (t: f32, hit: bool) {
  // |d + t*v|^2 = r^2 with d = pos_a - pos_b:
  // v·v*t^2 + 2*d·v*t + d·d - r^2 = 0
  d := pos_a - pos_b
  radius_sum := radius_a + radius_b
  a := linalg.length2(velocity_a)
  b := 2.0 * linalg.dot(d, velocity_a)
  c := linalg.length2(d) - radius_sum * radius_sum
  if a < math.F32_EPSILON do return 0, c <= 0
  discriminant := b * b - 4.0 * a * c
  if discriminant < 0 do return
  sqrt_disc := math.sqrt(discriminant)
  // Earlier root is the first impact; the later one means A starts inside
  t = (-b - sqrt_disc) / (2.0 * a)
  if t < 0 do t = (-b + sqrt_disc) / (2.0 * a)
  if t < 0 || t > 1.0 do return 0, false
  return t, true
}

// Sphere moving by `velocity` against a box (possibly rotated). The sweep
// runs in the box's local frame, where the sphere's center sweeps like a
// point against the box grown by the radius.
@(private)
swept_sphere_box :: proc(
  center: [3]f32,
  radius: f32,
  velocity: [3]f32,
  box_center: [3]f32,
  box_rotation: quaternion128,
  half_extents: [3]f32,
) -> (t: f32, hit: bool) {
  inv_rot := linalg.quaternion_inverse(box_rotation)
  local_origin := linalg.mul(inv_rot, center - box_center)
  local_velocity := linalg.mul(inv_rot, velocity)
  r := half_extents + radius
  return sweep_point_aabb(local_origin, local_velocity, {-r, r})
}

@(private)
swept_box_box :: proc(
  pos_a, pos_b: [3]f32,
  half_extents_a, half_extents_b: [3]f32,
  velocity_a: [3]f32,
) -> (t: f32, hit: bool) {
  sum := half_extents_a + half_extents_b
  return sweep_point_aabb(pos_a, velocity_a, {pos_b - sum, pos_b + sum})
}

// Slab test of the segment origin..origin+velocity against an AABB.
@(private = "file")
sweep_point_aabb :: proc(origin, velocity: [3]f32, box: geometry.Aabb) -> (t: f32, hit: bool) {
  t_near, t_far := geometry.ray_aabb_intersection(origin, 1.0 / velocity, box)
  if t_near > t_far || t_near < 0 || t_near > 1.0 do return 0, false
  return t_near, true
}

// Conservative sweep radius for the sphere-sphere fallback: exact for
// spheres, radial for cylinders (heights ignored, same as narrowphase
// approximation), bounding sphere for boxes.
@(private = "file")
swept_radius :: proc(c: ^Collider) -> f32 {
  switch s in c {
  case SphereCollider:
    return s.radius
  case BoxCollider:
    return linalg.length(s.half_extents)
  case CylinderCollider:
    return s.radius
  }
  return 0
}

// TOI of A moving by velocity_a against a stationary B. Exact slab tests for
// sphere/cylinder-vs-box and aligned box-box; everything else falls back to a
// conservative swept-sphere approximation.
@(private)
swept_test :: proc(
  collider_a, collider_b: ^Collider,
  pos_a, pos_b: [3]f32,
  rot_a, rot_b: quaternion128,
  velocity_a: [3]f32,
) -> (t: f32, hit: bool) {
  #partial switch shape_a in collider_a {
  case SphereCollider:
    if box_b, is_box := collider_b^.(BoxCollider); is_box {
      return swept_sphere_box(pos_a, shape_a.radius, velocity_a, pos_b, rot_b, box_b.half_extents)
    }
  case CylinderCollider:
    if box_b, is_box := collider_b^.(BoxCollider); is_box {
      return swept_sphere_box(pos_a, shape_a.radius, velocity_a, pos_b, rot_b, box_b.half_extents)
    }
  case BoxCollider:
    if sph_b, is_sphere := collider_b^.(SphereCollider); is_sphere {
      return swept_sphere_box(pos_b, sph_b.radius, -velocity_a, pos_a, rot_a, shape_a.half_extents)
    }
    box_b, is_box := collider_b^.(BoxCollider)
    if is_box && geometry.is_identity_quaternion(rot_a) && geometry.is_identity_quaternion(rot_b) {
      return swept_box_box(pos_a, pos_b, shape_a.half_extents, box_b.half_extents, velocity_a)
    }
  }
  return swept_sphere_sphere(
    pos_a, pos_b,
    swept_radius(collider_a), swept_radius(collider_b),
    velocity_a,
  )
}

// Sweeps a fast dynamic body against static geometry and parks it just
// short of the earliest impact; narrowphase runs after CCD this frame and
// the speculative contact stops the remaining approach.
@(private)
ccd_step_body :: proc(
  world: ^World,
  body_a: ^Body,
  idx_a: int,
  dt: f32,
  ccd_handled: []bool,
  static_candidates: ^[dynamic]BodyHandle,
) -> (tested: bool, candidate_count: int) {
  if !is_dynamic(body_a) || body_a.is_sleeping do return
  collider_a := &body_a.collider
  motion := body_a.velocity * dt
  threshold := 0.5 * collider_min_extent(collider_a)
  if linalg.length2(motion) < threshold * threshold do return
  tested = true
  earliest_toi := f32(1.0)
  swept_aabb := geometry.Aabb {
    min = linalg.min(body_a.cached_aabb.min, body_a.cached_aabb.min + motion),
    max = linalg.max(body_a.cached_aabb.max, body_a.cached_aabb.max + motion),
  }
  clear(static_candidates)
  geometry.bvh_query_aabb(&world.static_bvh, swept_aabb, static_candidates)
  candidate_count = len(static_candidates)
  for candidate in static_candidates {
    body_b := lookup(world, candidate) or_continue
    toi, hit := swept_test(collider_a, &body_b.collider, body_a.position, body_b.position, body_a.rotation, body_b.rotation, motion)
    if hit do earliest_toi = min(earliest_toi, toi)
  }
  if earliest_toi <= 0.01 || earliest_toi >= 0.99 do return
  body_a.position += motion * (earliest_toi * 0.98)
  update_cached_aabb(body_a)
  ccd_handled[idx_a] = true
  return
}

@(private = "file")
CCDContext :: struct {
  dt:               f32,
  ccd_handled:      []bool,
  bodies_tested:    []int, // per task
  total_candidates: []int, // per task
}

@(private)
ccd :: proc(world: ^World, dt: f32, ccd_handled: []bool) -> (bodies_tested, total_candidates: int) {
  tasks := max(1, world.thread_count)
  ctx := CCDContext {
    dt               = dt,
    ccd_handled      = ccd_handled,
    bodies_tested    = make([]int, tasks, context.temp_allocator),
    total_candidates = make([]int, tasks, context.temp_allocator),
  }
  parallel_for(world, body_range(world), &ctx, proc(world: ^World, ctx: rawptr, task, start, end: int) {
    ctx := (^CCDContext)(ctx)
    candidates := make([dynamic]BodyHandle, 0, 64)
    defer delete(candidates)
    #no_bounds_check for i in start ..< end {
      if !containers.slots_live(&world.body_slots, u32(i)) do continue
      tested, count := ccd_step_body(world, &world.bodies[i], i, ctx.dt, ctx.ccd_handled, &candidates)
      if tested do ctx.bodies_tested[task] += 1
      ctx.total_candidates[task] += count
    }
  })
  for i in 0 ..< tasks {
    bodies_tested += ctx.bodies_tested[i]
    total_candidates += ctx.total_candidates[i]
  }
  return
}
