package physics

import "../containers"
import "../geometry"
import "core:math"
import "core:math/linalg"

// MAX_JOINTS is how many joints a World holds at once.
MAX_JOINTS :: #config(PHYSICS_MAX_JOINTS, 4096)

@(private = "file")
JOINT_HERTZ :: 60.0
@(private = "file")
JOINT_DAMPING_RATIO :: 2.0
@(private = "file")
JOINT_MAX_PUSH_SPEED :: 10.0 // m/s cap on anchor drift recovery

// JointHandle is a generational handle to a joint in a World.
JointHandle :: distinct Handle

// BallJoint keeps one point of two bodies together and lets them swing freely, or within `cone`.
// Everything is given in world space for the poses the bodies have when the joint is created.
BallJoint :: struct {
  anchor: [3]f32,
  axis:   [3]f32, // direction the cone is measured around; ignored when cone is 0
  cone:   f32, // largest angle between the two bodies' axes, in radians; 0 = unlimited
}

// HingeJoint keeps one point of two bodies together and lets them turn about `axis` only.
// The turn angle is zero at the poses the bodies have when the joint is created, positive
// counter-clockwise about axis seen from its tip. The angle is limited when upper > lower.
HingeJoint :: struct {
  anchor: [3]f32,
  axis:   [3]f32,
  lower:  f32, // radians
  upper:  f32, // radians
}

// Joint is a constraint between two bodies, see BallJoint and HingeJoint.
Joint :: union {
  BallJoint,
  HingeJoint,
}

@(private)
JointData :: struct {
  hinge:           bool,
  limited:         bool,
  body_a:          BodyHandle,
  body_b:          BodyHandle, // none = anchored to the world
  local_a:         [3]f32, // anchor in each body's frame; a world point when body_b is none
  local_b:         [3]f32,
  axis_a:          [3]f32,
  axis_b:          [3]f32,
  ref_a:           [3]f32, // hinge: reference direction normal to the axis, zero angle when aligned
  ref_b:           [3]f32,
  cone:            f32,
  lower:           f32,
  upper:           f32,
  point_impulse:   [3]f32,
  angular_impulse: [3]f32,
  limit_impulse:   [2]f32,
}

// joint_create connects body_a to body_b with joint. A body_b of none anchors body_a to
// the world at the joint's anchor point, which joint_anchor can then move.
// Bodies joined by a joint do not collide with each other.
joint_create :: proc(
  self: ^World,
  body_a, body_b: BodyHandle,
  joint: Joint,
) -> (
  handle: JointHandle,
  ok: bool,
) #optional_ok {
  a := lookup(self, body_a) or_return
  b: ^Body
  if body_b != {} do b = lookup(self, body_b) or_return
  index := containers.slots_alloc(&self.joint_slots) or_return
  j := &self.joints[index]
  j^ = {
    body_a = body_a,
    body_b = body_b,
  }
  anchor, axis: [3]f32
  switch v in joint {
  case BallJoint:
    anchor, axis = v.anchor, v.axis
    j.cone = v.cone
    j.limited = v.cone > 0
  case HingeJoint:
    anchor, axis = v.anchor, v.axis
    j.hinge = true
    j.lower, j.upper = v.lower, v.upper
    j.limited = v.upper > v.lower
  }
  axis = linalg.length2(axis) > math.F32_EPSILON ? linalg.normalize(axis) : {0, 1, 0}
  ref, _ := geometry.tangent_basis(axis)
  ref = linalg.normalize(ref)
  j.local_a = to_local(a, anchor)
  j.axis_a = to_local_dir(a, axis)
  j.ref_a = to_local_dir(a, ref)
  if b != nil {
    j.local_b = to_local(b, anchor)
    j.axis_b = to_local_dir(b, axis)
    j.ref_b = to_local_dir(b, ref)
    b.jointed = true
    wake_up(b)
  } else {
    j.local_b = anchor
    j.axis_b = axis
    j.ref_b = ref
  }
  a.jointed = true
  wake_up(a)
  return JointHandle(containers.slots_handle(&self.joint_slots, index)), true
}

// joint_destroy frees the joint behind handle; a stale handle is ignored.
joint_destroy :: proc(self: ^World, handle: JointHandle) {
  if !containers.slots_valid(&self.joint_slots, handle) do return
  containers.slots_free(&self.joint_slots, handle.index)
}

// joint_anchor moves the joint's anchor point on body_b to a world-space point and wakes the
// bodies. Use it to drag a world-anchored body around.
joint_anchor :: proc(self: ^World, handle: JointHandle, point: [3]f32) {
  if !containers.slots_valid(&self.joint_slots, handle) do return
  j := &self.joints[handle.index]
  if j.body_b == {} {
    j.local_b = point
  } else {
    if b, ok := lookup(self, j.body_b); ok {
      j.local_b = to_local(b, point)
      wake_up(b)
    }
  }
  if a, ok := lookup(self, j.body_a); ok do wake_up(a)
}

@(private)
to_local :: proc(body: ^Body, point: [3]f32) -> [3]f32 {
  return to_local_dir(body, point - body.position)
}

@(private)
to_local_dir :: proc(body: ^Body, dir: [3]f32) -> [3]f32 {
  return linalg.mul(linalg.quaternion_inverse(body.rotation), dir)
}

@(private)
joints_destroy_of :: proc(self: ^World, body: BodyHandle) {
  c: u32
  for i in containers.slots_next(&self.joint_slots, &c) {
    j := &self.joints[i]
    if j.body_a == body || j.body_b == body do containers.slots_free(&self.joint_slots, i)
  }
}

@(private)
joint_between :: proc(self: ^World, a, b: BodyHandle) -> bool {
  c: u32
  for i in containers.slots_next(&self.joint_slots, &c) {
    j := &self.joints[i]
    if (j.body_a == a && j.body_b == b) || (j.body_a == b && j.body_b == a) do return true
  }
  return false
}

@(private)
joint_bodies :: proc(world: ^World, j: ^JointData, world_body: ^Body) -> (a, b: ^Body, ok: bool) {
  a = lookup(world, j.body_a) or_return
  if j.body_b == {} do return a, world_body, true
  b = lookup(world, j.body_b) or_return
  return a, b, true
}

@(private = "file")
joint_awake :: #force_inline proc(body: ^Body) -> bool {
  return body.inv_mass > 0 && body.moving && !body.is_sleeping
}

@(private)
joint_active :: #force_inline proc(a, b: ^Body) -> bool {
  return joint_awake(a) || joint_awake(b)
}

// A joint wakes both of its bodies together; the island pass keeps them asleep together.
@(private)
step_wake_joints :: proc(world: ^World) {
  world_body: Body
  c: u32
  for i in containers.slots_next(&world.joint_slots, &c) {
    a, b, ok := joint_bodies(world, &world.joints[i], &world_body)
    if !ok do continue
    if joint_awake(a) && b.inv_mass > 0 && b.is_sleeping do wake_up(b)
    if joint_awake(b) && a.inv_mass > 0 && a.is_sleeping do wake_up(a)
  }
}

@(private = "file")
LimitRow :: struct {
  normal: [3]f32, // pushing B along it widens the gap
  gap:    f32, // room left before the limit, negative when past it
}

@(private = "file")
joint_limits :: proc(j: ^JointData, a, b: ^Body) -> (rows: [2]LimitRow, count: int) {
  if !j.limited do return
  ua := linalg.mul(a.rotation, j.axis_a)
  ub := linalg.mul(b.rotation, j.axis_b)
  if !j.hinge {
    n := linalg.cross(ua, ub)
    l := linalg.length(n)
    if l < 1e-6 do return
    theta := math.acos(clamp(linalg.dot(ua, ub), -1, 1))
    rows[0] = {-n / l, j.cone - theta}
    return rows, 1
  }
  ra := linalg.mul(a.rotation, j.ref_a)
  rb := linalg.mul(b.rotation, j.ref_b)
  phi := math.atan2(linalg.dot(ua, linalg.cross(ra, rb)), linalg.dot(ra, rb))
  rows[0] = {ua, phi - j.lower}
  rows[1] = {-ua, j.upper - phi}
  return rows, 2
}

@(private)
warmstart_joints :: proc(world: ^World) {
  world_body: Body
  world_body.rotation = linalg.QUATERNIONF32_IDENTITY
  c: u32
  for i in containers.slots_next(&world.joint_slots, &c) {
    j := &world.joints[i]
    a, b, ok := joint_bodies(world, j, &world_body)
    if !ok || !joint_active(a, b) do continue
    pa := a.position + linalg.mul(a.rotation, j.local_a)
    pb := b.position + linalg.mul(b.rotation, j.local_b)
    apply_impulse_at_point(a, -j.point_impulse, pa)
    apply_impulse_at_point(b, j.point_impulse, pb)
    apply_angular_impulse(a, -j.angular_impulse)
    apply_angular_impulse(b, j.angular_impulse)
    rows, count := joint_limits(j, a, b)
    for k in 0 ..< count {
      apply_angular_impulse(a, -rows[k].normal * j.limit_impulse[k])
      apply_angular_impulse(b, rows[k].normal * j.limit_impulse[k])
    }
  }
}

@(private)
solve_joints :: proc(world: ^World, soft: Softness, inv_h: f32, use_bias: bool) {
  world_body: Body
  world_body.rotation = linalg.QUATERNIONF32_IDENTITY
  c: u32
  for i in containers.slots_next(&world.joint_slots, &c) {
    j := &world.joints[i]
    a, b, ok := joint_bodies(world, j, &world_body)
    if !ok || !joint_active(a, b) do continue
    if j.hinge do solve_hinge_axis(j, a, b, soft, use_bias)
    rows, count := joint_limits(j, a, b)
    for k in 0 ..< count do solve_limit(&j.limit_impulse[k], rows[k], a, b, soft, inv_h, use_bias)
    solve_point(j, a, b, soft, use_bias)
  }
}

@(private = "file")
solve_point :: proc(j: ^JointData, a, b: ^Body, soft: Softness, use_bias: bool) {
  ra := linalg.mul(a.rotation, j.local_a)
  rb := linalg.mul(b.rotation, j.local_b)
  sa := geometry.skew(ra)
  sb := geometry.skew(rb)
  m := a.inv_mass + b.inv_mass
  k := matrix[3, 3]f32{
    m, 0, 0,
    0, m, 0,
    0, 0, m,
  }
  k -= sa * a.inv_inertia_world * sa + sb * b.inv_inertia_world * sb
  if math.abs(linalg.determinant(k)) < 1e-12 do return
  err := (b.position + rb) - (a.position + ra)
  cdot := (b.velocity + linalg.cross(b.angular_velocity, rb)) - (a.velocity + linalg.cross(a.angular_velocity, ra))
  bias: [3]f32
  mass_scale, impulse_scale: f32 = 1, 0
  if use_bias {
    bias = soft.bias_rate * err
    if l := linalg.length(bias); l > JOINT_MAX_PUSH_SPEED do bias *= JOINT_MAX_PUSH_SPEED / l
    mass_scale, impulse_scale = soft.mass_scale, soft.impulse_scale
  }
  p := -mass_scale * (linalg.inverse(k) * (cdot + bias)) - impulse_scale * j.point_impulse
  j.point_impulse += p
  apply_impulse_at_point(a, -p, a.position + ra)
  apply_impulse_at_point(b, p, b.position + rb)
}

// Keeps both bodies' hinge axes parallel: two angular rows normal to the axis, solved together.
@(private = "file")
solve_hinge_axis :: proc(j: ^JointData, a, b: ^Body, soft: Softness, use_bias: bool) {
  ua := linalg.mul(a.rotation, j.axis_a)
  ub := linalg.mul(b.rotation, j.axis_b)
  t1, t2 := geometry.tangent_basis(ua)
  iw := a.inv_inertia_world + b.inv_inertia_world
  i1 := iw * t1
  i2 := iw * t2
  k11, k12, k22 := linalg.dot(t1, i1), linalg.dot(t2, i1), linalg.dot(t2, i2)
  det := k11 * k22 - k12 * k12
  if math.abs(det) < 1e-12 do return
  err := linalg.cross(ua, ub)
  wrel := b.angular_velocity - a.angular_velocity
  rhs := [2]f32{linalg.dot(wrel, t1), linalg.dot(wrel, t2)}
  mass_scale, impulse_scale: f32 = 1, 0
  if use_bias {
    rhs += soft.bias_rate * [2]f32{linalg.dot(err, t1), linalg.dot(err, t2)}
    mass_scale, impulse_scale = soft.mass_scale, soft.impulse_scale
  }
  rhs *= mass_scale
  rhs += impulse_scale * [2]f32{linalg.dot(j.angular_impulse, t1), linalg.dot(j.angular_impulse, t2)}
  p := [2]f32{-(k22 * rhs[0] - k12 * rhs[1]) / det, -(k11 * rhs[1] - k12 * rhs[0]) / det}
  impulse := t1 * p[0] + t2 * p[1]
  j.angular_impulse += impulse
  apply_angular_impulse(a, -impulse)
  apply_angular_impulse(b, impulse)
}

// One-sided angular limit; speculative before it is reached, soft once past it, like a contact.
@(private = "file")
solve_limit :: proc(
  accumulated: ^f32,
  row: LimitRow,
  a, b: ^Body,
  soft: Softness,
  inv_h: f32,
  use_bias: bool,
) {
  k := linalg.dot(row.normal, (a.inv_inertia_world + b.inv_inertia_world) * row.normal)
  if k < math.F32_EPSILON do return
  vn := linalg.dot(b.angular_velocity - a.angular_velocity, row.normal)
  bias: f32
  mass_scale, impulse_scale: f32 = 1, 0
  if row.gap > 0 {
    bias = row.gap * inv_h
  } else if use_bias {
    bias = max(soft.bias_rate * row.gap, -JOINT_MAX_PUSH_SPEED)
    mass_scale, impulse_scale = soft.mass_scale, soft.impulse_scale
  }
  old := accumulated^
  accumulated^ = max(old - mass_scale * (vn + bias) / k - impulse_scale * old, 0)
  d := row.normal * (accumulated^ - old)
  apply_angular_impulse(a, -d)
  apply_angular_impulse(b, d)
}

@(private)
joint_softness :: proc "contextless" (h: f32) -> Softness {
  inv_h := h > 0 ? 1.0 / h : 0
  return make_soft(min(JOINT_HERTZ, 0.25 * inv_h), JOINT_DAMPING_RATIO, h)
}
