#+private
package physics

// Narrowphase: broadphase pairs → analytic contacts (sphere, box, cylinder). Multi-point
// manifolds let boxes rest flat. Every normal points from A to B.

import "../geometry"
import "core:math"
import "core:math/linalg"

MAX_MANIFOLD_POINTS :: 4

// Warmstart pair keys include handle generations so a recycled slot never
// inherits the previous occupant's impulses.
@(private)
collision_pair_hash :: proc "contextless" (body_a, body_b: BodyHandle) -> u64 {
  ha := u64(body_a.index) | (u64(body_a.generation) << 32)
  hb := u64(body_b.index) | (u64(body_b.generation) << 32)
  return ha * 0x9E3779B97F4A7C15 ~ (hb + 0x517CC1B727220A95)
}

@(private)
mix_friction :: #force_inline proc "contextless" (a, b: f32) -> f32 {
  return math.sqrt(a * b)
}

@(private)
mix_restitution :: #force_inline proc "contextless" (a, b: f32) -> f32 {
  return max(a, b)
}

@(private)
ContactWarmstart :: struct {
  count:           int,
  feature_ids:     [MAX_MANIFOLD_POINTS]u32,
  normal_impulses: [MAX_MANIFOLD_POINTS]f32,
  tangent:         [2]f32,
  twist:           f32,
}

@(private)
contact_has_impulse :: #force_inline proc(c: ^Contact) -> bool {
  if c.tangent_impulse != {0, 0} || c.twist_impulse != 0 do return true
  for i in 0 ..< c.count {
    if c.points[i].normal_impulse != 0 do return true
  }
  return false
}

@(private)
contact_store_warmstart :: proc(c: ^Contact) -> (w: ContactWarmstart) {
  w.count = c.count
  for i in 0 ..< c.count {
    w.feature_ids[i] = c.points[i].feature_id
    w.normal_impulses[i] = c.points[i].normal_impulse
  }
  w.tangent = c.tangent_impulse
  w.twist = c.twist_impulse
  return
}

@(private)
contact_apply_warmstart :: proc(c: ^Contact, w: ^ContactWarmstart) {
  for i in 0 ..< c.count {
    for j in 0 ..< w.count {
      if c.points[i].feature_id == w.feature_ids[j] {
        c.points[i].normal_impulse = w.normal_impulses[j]
        break
      }
    }
  }
  c.tangent_impulse = w.tangent
  c.twist_impulse = w.twist
}

@(private)
bounding_spheres_intersect :: proc "contextless" (
  pos_a: [3]f32,
  radius_a: f32,
  pos_b: [3]f32,
  radius_b: f32,
) -> bool {
  radius_sum := radius_a + radius_b
  return linalg.length2(pos_b - pos_a) <= radius_sum * radius_sum
}

@(private)
test_sphere_sphere :: proc(
  pos_a: [3]f32,
  sphere_a: SphereCollider,
  pos_b: [3]f32,
  sphere_b: SphereCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  delta := pos_b - pos_a
  distance_sq := linalg.length2(delta)
  radius_sum := sphere_a.radius + sphere_b.radius
  if distance_sq > radius_sum * radius_sum do return
  distance := math.sqrt(distance_sq)
  normal = distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = radius_sum - distance
  point = pos_a + normal * (sphere_a.radius - penetration * 0.5)
  hit = true
  return
}

// Point is the closest point on the box; normal points box → sphere. A
// center inside the box gets the Y axis.
@(private)
test_box_sphere :: proc(
  pos_box: [3]f32,
  rot_box: quaternion128,
  box: BoxCollider,
  pos_sphere: [3]f32,
  sphere: SphereCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  point = geometry.obb_closest_point({center = pos_box, half_extents = box.half_extents, rotation = rot_box}, pos_sphere)
  delta := pos_sphere - point
  dist_sq := linalg.length2(delta)
  if dist_sq > sphere.radius * sphere.radius do return
  distance := math.sqrt(dist_sq)
  normal = distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = sphere.radius - distance
  hit = true
  return
}

// Normal points sphere → cylinder, taken from the cylinder surface (stable
// under deep penetration).
@(private)
test_sphere_cylinder :: proc(
  pos_sphere: [3]f32,
  sphere: SphereCollider,
  pos_cylinder: [3]f32,
  rot_cylinder: quaternion128,
  cylinder: CylinderCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  inv_rot := linalg.quaternion_inverse(rot_cylinder)
  local_sphere := geometry.qmv(inv_rot, pos_sphere - pos_cylinder)
  half_height := cylinder.height * 0.5
  radial := [3]f32{local_sphere.x, 0, local_sphere.z}
  radial_dist := linalg.length(radial)
  radial_dir := radial_dist > math.F32_EPSILON ? radial / radial_dist : [3]f32{1, 0, 0}
  rim := radial_dir * cylinder.radius
  above := local_sphere.y > half_height
  below := local_sphere.y < -half_height
  inside_radial := radial_dist < cylinder.radius
  local_closest: [3]f32
  if above || below {
    cap_y := above ? half_height : -half_height
    local_closest = inside_radial ? {local_sphere.x, cap_y, local_sphere.z} : {rim.x, cap_y, rim.z}
  } else if inside_radial {
    // Center inside the cylinder: push out along the shallowest direction
    dist_to_top := half_height - local_sphere.y
    dist_to_bottom := local_sphere.y + half_height
    dist_to_side := cylinder.radius - radial_dist
    if dist_to_side <= dist_to_top && dist_to_side <= dist_to_bottom {
      local_closest = {rim.x, local_sphere.y, rim.z}
    } else if dist_to_top <= dist_to_bottom {
      local_closest = {local_sphere.x, half_height, local_sphere.z}
    } else {
      local_closest = {local_sphere.x, -half_height, local_sphere.z}
    }
  } else {
    local_closest = {rim.x, local_sphere.y, rim.z}
  }
  local_normal: [3]f32
  if local_closest.y >= half_height - math.F32_EPSILON {
    local_normal = {0, 1, 0}
  } else if local_closest.y <= -half_height + math.F32_EPSILON {
    local_normal = {0, -1, 0}
  } else {
    local_normal = radial_dir
  }
  world_closest := pos_cylinder + geometry.qmv(rot_cylinder, local_closest)
  surface_normal := geometry.qmv(rot_cylinder, local_normal)
  dist_sq := linalg.length2(pos_sphere - world_closest)
  if dist_sq > sphere.radius * sphere.radius do return
  penetration = sphere.radius - math.sqrt(dist_sq)
  point = world_closest + surface_normal * (penetration * 0.5)
  normal = -surface_normal
  hit = true
  return
}

// Box vs cylinder axis segment: samples the segment for the point nearest the
// box, refines once, then tests that distance against the radius. Point is on
// the box; normal points box → cylinder.
@(private)
test_box_cylinder :: proc(
  pos_box: [3]f32,
  rot_box: quaternion128,
  box: BoxCollider,
  pos_cylinder: [3]f32,
  rot_cylinder: quaternion128,
  cylinder: CylinderCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  obb := geometry.Obb{center = pos_box, half_extents = box.half_extents, rotation = rot_box}
  axis := geometry.qy(rot_cylinder) * (cylinder.height * 0.5)
  seg_start := pos_cylinder - axis
  seg_end := pos_cylinder + axis
  min_dist_sq := f32(math.F32_MAX)
  #unroll for i in 0 ..= 4 {
    sample := linalg.mix(seg_start, seg_end, f32(i) / 4.0)
    on_box := geometry.obb_closest_point(obb, sample)
    if d := linalg.length2(sample - on_box); d < min_dist_sq {
      min_dist_sq = d
      point = on_box
    }
  }
  seg := seg_end - seg_start
  on_axis := pos_cylinder
  if seg_len_sq := linalg.length2(seg); seg_len_sq > 1e-6 {
    on_axis = linalg.mix(seg_start, seg_end, linalg.saturate(linalg.dot(point - seg_start, seg) / seg_len_sq))
    point = geometry.obb_closest_point(obb, on_axis)
  }
  delta := on_axis - point
  dist_sq := linalg.length2(delta)
  if dist_sq > cylinder.radius * cylinder.radius do return
  distance := math.sqrt(dist_sq)
  normal = distance > 1e-6 ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = cylinder.radius - distance
  hit = true
  return
}

// Non-parallel cylinders, approximated as capsules: closest points between
// the two axis segments against the radius sum.
@(private)
test_cylinder_cylinder :: proc(
  pos_a: [3]f32,
  rot_a: quaternion128,
  cylinder_a: CylinderCollider,
  pos_b: [3]f32,
  rot_b: quaternion128,
  cylinder_b: CylinderCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  axis_a := geometry.qy(rot_a) * (cylinder_a.height * 0.5)
  axis_b := geometry.qy(rot_b) * (cylinder_b.height * 0.5)
  p0_a := pos_a - axis_a
  p0_b := pos_b - axis_b
  d1 := 2 * axis_a
  d2 := 2 * axis_b
  r := p0_a - p0_b
  a := linalg.dot(d1, d1)
  e := linalg.dot(d2, d2)
  f := linalg.dot(d2, r)
  s, t: f32
  if a <= math.F32_EPSILON && e <= math.F32_EPSILON {
    s, t = 0, 0
  } else if a <= math.F32_EPSILON {
    t = clamp(f / e, 0.0, 1.0)
  } else {
    c := linalg.dot(d1, r)
    if e <= math.F32_EPSILON {
      s = clamp(-c / a, 0.0, 1.0)
    } else {
      b := linalg.dot(d1, d2)
      denom := a * e - b * b
      s = denom != 0 ? clamp((b * f - c * e) / denom, 0.0, 1.0) : 0
      t = (b * s + f) / e
      if t < 0 {
        t = 0
        s = clamp(-c / a, 0.0, 1.0)
      } else if t > 1 {
        t = 1
        s = clamp((b - c) / a, 0.0, 1.0)
      }
    }
  }
  c1 := p0_a + d1 * s
  c2 := p0_b + d2 * t
  delta := c2 - c1
  dist_sq := linalg.length2(delta)
  radius_sum := cylinder_a.radius + cylinder_b.radius
  if dist_sq > radius_sum * radius_sum do return
  distance := math.sqrt(dist_sq)
  normal = distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = radius_sum - distance
  point = c1 + normal * (cylinder_a.radius - penetration * 0.5)
  hit = true
  return
}

@(private)
ManifoldPoint :: struct {
  point:       [3]f32,
  penetration: f32,
  feature_id:  u32,
}

@(private)
Manifold :: struct {
  normal: [3]f32, // from A to B
  count:  int,
  points: [MAX_MANIFOLD_POINTS]ManifoldPoint,
}

@(private = "file")
FEATURE_EDGE_CONTACT :: u32(0xE0000000)
@(private = "file")
FEATURE_SINGLE :: u32(0xF0000000)

// Wraps a single-point test result. Sphere tests run with the radius
// inflated by `margin`; deflating the penetration back makes separated-but-
// within-margin contacts come out negative (speculative).
@(private)
point_manifold :: #force_inline proc(
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
  margin: f32 = 0,
) -> (m: Manifold, ok: bool) {
  if !hit do return
  m.normal = normal
  m.count = 1
  m.points[0] = {point = point, penetration = penetration - margin, feature_id = FEATURE_SINGLE}
  return m, true
}

@(private = "file")
BoxFrame :: struct {
  center: [3]f32,
  axes:   [3][3]f32, // world-space unit axes
  half:   [3]f32,
}

@(private = "file")
box_frame :: proc(pos: [3]f32, rot: quaternion128, half: [3]f32) -> (f: BoxFrame) {
  r := linalg.matrix3_from_quaternion(rot)
  f.center = pos
  f.axes = {
    {r[0, 0], r[1, 0], r[2, 0]},
    {r[0, 1], r[1, 1], r[2, 1]},
    {r[0, 2], r[1, 2], r[2, 2]},
  }
  f.half = half
  return
}

@(private = "file")
box_extent :: #force_inline proc(f: ^BoxFrame, dir: [3]f32) -> f32 {
  return(
    f.half.x * math.abs(linalg.dot(dir, f.axes[0])) +
    f.half.y * math.abs(linalg.dot(dir, f.axes[1])) +
    f.half.z * math.abs(linalg.dot(dir, f.axes[2])) \
  )
}

// World-space corners of face `axis_idx` (sign = ±1) of a box, CCW seen from
// outside. Corner order is deterministic — feature ids depend on it.
@(private = "file")
box_face_vertices :: proc(f: ^BoxFrame, axis_idx: int, sign: f32) -> (verts: [4][3]f32) {
  u_idx := (axis_idx + 1) % 3
  v_idx := (axis_idx + 2) % 3
  n := f.axes[axis_idx] * (sign * f.half[axis_idx])
  u := f.axes[u_idx] * f.half[u_idx]
  v := f.axes[v_idx] * f.half[v_idx]
  c := f.center + n
  verts[0] = c - u - v
  verts[1] = c + u - v
  verts[2] = c + u + v
  verts[3] = c - u + v
  return
}

@(private = "file")
ClipVertex :: struct {
  p:  [3]f32,
  id: u32,
}

// Sutherland-Hodgman clip of a polygon against plane dot(n,x) <= d.
// New vertices get ids derived from the edge they were created on plus the
// clip plane index, so they stay stable frame-to-frame.
@(private = "file")
clip_polygon_plane :: proc(
  poly: []ClipVertex,
  n: [3]f32,
  d: f32,
  plane_id: u32,
  out: ^[8]ClipVertex,
) -> (count: int) {
  n_in := len(poly)
  if n_in == 0 do return 0
  prev := poly[n_in - 1]
  prev_dist := linalg.dot(n, prev.p) - d
  for i in 0 ..< n_in {
    cur := poly[i]
    cur_dist := linalg.dot(n, cur.p) - d
    if prev_dist <= 0 && count < 8 {
      out[count] = prev
      count += 1
    }
    if (prev_dist < 0) != (cur_dist < 0) && count < 8 {
      t := prev_dist / (prev_dist - cur_dist)
      out[count] = {
        p  = prev.p + (cur.p - prev.p) * t,
        id = (prev.id ~ cur.id) << 8 | plane_id | 0x40000000,
      }
      count += 1
    }
    prev = cur
    prev_dist = cur_dist
  }
  return
}

// Reduce n candidate points to <=4 keeping the deepest point and maximal
@(private = "file")
reduce_manifold :: proc(m: ^Manifold, candidates: []ManifoldPoint) {
  n := len(candidates)
  if n <= MAX_MANIFOLD_POINTS {
    for c, i in candidates do m.points[i] = c
    m.count = n
    return
  }
  best := 0
  for i in 1 ..< n {
    if candidates[i].penetration > candidates[best].penetration do best = i
  }
  m.points[0] = candidates[best]
  best2, best_d := 0, f32(-1)
  for c, i in candidates {
    d := linalg.length2(c.point - m.points[0].point)
    if d > best_d {
      best_d = d
      best2 = i
    }
  }
  m.points[1] = candidates[best2]
  best3, best_a := 0, f32(-1)
  e01 := m.points[1].point - m.points[0].point
  for c, i in candidates {
    a := linalg.length2(linalg.cross(e01, c.point - m.points[0].point))
    if a > best_a {
      best_a = a
      best3 = i
    }
  }
  m.points[2] = candidates[best3]
  centroid := (m.points[0].point + m.points[1].point + m.points[2].point) / 3
  best4, best_d4 := 0, f32(-1)
  for c, i in candidates {
    d := linalg.length2(c.point - centroid)
    if d > best_d4 {
      best_d4 = d
      best4 = i
    }
  }
  m.points[3] = candidates[best4]
  m.count = 4
}

// Axis-aligned fast path: overlap box, face manifold on the min axis.
@(private = "file")
collide_boxes_aligned :: proc(
  pos_a: [3]f32,
  half_a: [3]f32,
  pos_b: [3]f32,
  half_b: [3]f32,
  margin: f32,
) -> (m: Manifold, hit: bool) {
  min_a := pos_a - half_a
  max_a := pos_a + half_a
  min_b := pos_b - half_b
  max_b := pos_b + half_b
  overlap_min := linalg.max(min_a, min_b)
  overlap_max := linalg.min(max_a, max_b)
  overlap := overlap_max - overlap_min
  // Speculative: accept up to `margin` of separation on one axis
  if overlap.x < -margin || overlap.y < -margin || overlap.z < -margin {
    return
  }
  axis := 0
  if overlap.y < overlap[axis] do axis = 1
  if overlap.z < overlap[axis] do axis = 2
  pen := overlap[axis]
  for k in 0 ..< 3 {
    if overlap_min[k] > overlap_max[k] {
      mid := (overlap_min[k] + overlap_max[k]) * 0.5
      overlap_min[k] = mid
      overlap_max[k] = mid
    }
  }
  sign: f32 = pos_b[axis] > pos_a[axis] ? 1 : -1
  normal: [3]f32
  normal[axis] = sign
  plane := sign > 0 ? max_a[axis] : min_a[axis]
  u := (axis + 1) % 3
  v := (axis + 2) % 3
  m.normal = normal
  corners := [4][2]f32{
    {overlap_min[u], overlap_min[v]},
    {overlap_max[u], overlap_min[v]},
    {overlap_max[u], overlap_max[v]},
    {overlap_min[u], overlap_max[v]},
  }
  count := 0
  for c, i in corners {
    p: [3]f32
    p[axis] = plane
    p[u] = c[0]
    p[v] = c[1]
    // Degenerate overlap (edge/corner touch) produces duplicate corners; skip
    if count > 0 && linalg.length2(p - m.points[count - 1].point) < 1e-12 do continue
    m.points[count] = {
      point       = p,
      penetration = pen,
      feature_id  = u32(axis) << 4 | u32(i),
    }
    count += 1
  }
  m.count = count
  hit = count > 0
  return
}

@(private)
collide_boxes :: proc(
  pos_a: [3]f32,
  rot_a: quaternion128,
  box_a: BoxCollider,
  pos_b: [3]f32,
  rot_b: quaternion128,
  box_b: BoxCollider,
  margin: f32,
) -> (m: Manifold, hit: bool) {
  if geometry.is_identity_quaternion(rot_a) && geometry.is_identity_quaternion(rot_b) {
    return collide_boxes_aligned(pos_a, box_a.half_extents, pos_b, box_b.half_extents, margin)
  }
  fa := box_frame(pos_a, rot_a, box_a.half_extents)
  fb := box_frame(pos_b, rot_b, box_b.half_extents)
  d := fb.center - fa.center

  best_pen := f32(math.F32_MAX)
  best_axis: [3]f32
  best_face_owner := -1 // 0 = A's face, 1 = B's face
  best_face_idx := -1

  for owner in 0 ..< 2 {
    f := owner == 0 ? &fa : &fb
    for i in 0 ..< 3 {
      axis := f.axes[i]
      dist := linalg.dot(d, axis)
      if dist < 0 do axis = -axis
      pen := box_extent(&fa, axis) + box_extent(&fb, axis) - math.abs(dist)
      if pen < -margin do return
      if pen < best_pen {
        best_pen = pen
        best_axis = axis
        best_face_owner = owner
        best_face_idx = i
      }
    }
  }

  // Edge-edge axes. Small relative bias prefers faces to avoid feature
  // flip-flop (box2d convention).
  EDGE_BIAS :: f32(0.95)
  EDGE_ABS_BIAS :: f32(0.01)
  best_edge_pen := f32(math.F32_MAX)
  best_edge_axis: [3]f32
  best_edge_a, best_edge_b := -1, -1
  for i in 0 ..< 3 {
    for j in 0 ..< 3 {
      axis := linalg.cross(fa.axes[i], fb.axes[j])
      len_sq := linalg.length2(axis)
      if len_sq < 1e-6 do continue // parallel edges — face axes cover this
      axis /= math.sqrt(len_sq)
      if linalg.dot(d, axis) < 0 do axis = -axis
      pen := box_extent(&fa, axis) + box_extent(&fb, axis) - math.abs(linalg.dot(d, axis))
      if pen < -margin do return
      if pen < best_edge_pen {
        best_edge_pen = pen
        best_edge_axis = axis
        best_edge_a = i
        best_edge_b = j
      }
    }
  }

  if best_edge_a >= 0 && best_edge_pen * EDGE_BIAS < best_pen - EDGE_ABS_BIAS {
    m.normal = best_edge_axis
    pa := fa.center
    for i in 0 ..< 3 {
      s: f32 = linalg.dot(best_edge_axis, fa.axes[i]) > 0 ? 1 : -1
      if i == best_edge_a do continue
      pa += fa.axes[i] * (s * fa.half[i])
    }
    pb := fb.center
    for i in 0 ..< 3 {
      s: f32 = linalg.dot(best_edge_axis, fb.axes[i]) > 0 ? -1 : 1
      if i == best_edge_b do continue
      pb += fb.axes[i] * (s * fb.half[i])
    }
    ea := fa.axes[best_edge_a]
    eb := fb.axes[best_edge_b]
    r := pb - pa
    a_dot_b := linalg.dot(ea, eb)
    denom := 1 - a_dot_b * a_dot_b
    s_par: f32 = 0
    if math.abs(denom) > 1e-6 {
      s_par = clamp(
        (linalg.dot(r, ea) - linalg.dot(r, eb) * a_dot_b) / denom,
        -fa.half[best_edge_a],
        fa.half[best_edge_a],
      )
    }
    p_edge_a := pa + ea * s_par
    t_par := clamp(linalg.dot(p_edge_a - pb, eb), -fb.half[best_edge_b], fb.half[best_edge_b])
    p_edge_b := pb + eb * t_par
    m.count = 1
    m.points[0] = {
      point       = (p_edge_a + p_edge_b) * 0.5,
      penetration = best_edge_pen,
      feature_id  = FEATURE_EDGE_CONTACT | u32(best_edge_a) << 8 | u32(best_edge_b),
    }
    hit = true
    return
  }

  ref := best_face_owner == 0 ? &fa : &fb
  inc := best_face_owner == 0 ? &fb : &fa
  ref_normal := best_axis
  ref_face_normal := best_face_owner == 0 ? ref_normal : -ref_normal
  ref_sign: f32 = linalg.dot(ref.axes[best_face_idx], ref_face_normal) > 0 ? 1 : -1

  inc_idx := 0
  inc_dot := f32(math.F32_MAX)
  inc_sign: f32 = 1
  for i in 0 ..< 3 {
    dp := linalg.dot(inc.axes[i], ref_face_normal)
    if dp < inc_dot {
      inc_dot = dp
      inc_idx = i
      inc_sign = 1
    }
    if -dp < inc_dot {
      inc_dot = -dp
      inc_idx = i
      inc_sign = -1
    }
  }

  inc_verts := box_face_vertices(inc, inc_idx, inc_sign)
  poly: [8]ClipVertex
  poly_count := 4
  for v, i in inc_verts {
    poly[i] = {p = v, id = u32(inc_idx) << 16 | u32(i)}
  }

  tmp: [8]ClipVertex
  for k in 0 ..< 3 {
    if k == best_face_idx do continue
    for dir in 0 ..< 2 {
      n := dir == 0 ? ref.axes[k] : -ref.axes[k]
      dd := linalg.dot(n, ref.center) + ref.half[k]
      plane_id := u32(k) << 1 | u32(dir)
      cnt := clip_polygon_plane(poly[:poly_count], n, dd, plane_id, &tmp)
      poly = tmp
      poly_count = cnt
      if poly_count == 0 do return
    }
  }

  face_center := ref.center + ref.axes[best_face_idx] * (ref_sign * ref.half[best_face_idx])
  candidates: [8]ManifoldPoint
  cand_count := 0
  for i in 0 ..< poly_count {
    sep := linalg.dot(ref_face_normal, poly[i].p - face_center)
    if sep <= margin {
      candidates[cand_count] = {
        point       = poly[i].p - ref_face_normal * (sep * 0.5),
        penetration = -sep,
        feature_id  = poly[i].id | u32(best_face_owner) << 30,
      }
      cand_count += 1
    }
  }
  if cand_count == 0 do return
  m.normal = ref_normal
  reduce_manifold(&m, candidates[:cand_count])
  hit = true
  return
}

// Cap-contact rim points: 4 samples on the contact circle, clipped to
// penetrating ones. Leaves `m` untouched when the contact is not a cap
// resting case.
@(private = "file")
cylinder_cap_manifold :: proc(
  m: ^Manifold,
  cyl_pos: [3]f32,
  cyl_rot: quaternion128,
  radius: f32,
  height: f32,
  plane_point: [3]f32, // point on the opposing face plane
  plane_normal: [3]f32, // toward the cylinder
  margin: f32,
) {
  axis := geometry.qy(cyl_rot)
  cap_dot := linalg.dot(axis, plane_normal)
  if math.abs(cap_dot) < 0.966 do return // cos(15°)
  cap_sign: f32 = cap_dot > 0 ? -1 : 1
  cap_center := cyl_pos + axis * (cap_sign * height * 0.5)
  t1 := linalg.normalize(linalg.orthogonal(axis))
  t2 := linalg.cross(axis, t1)
  points: [MAX_MANIFOLD_POINTS]ManifoldPoint
  count := 0
  for i in 0 ..< 4 {
    dir := i == 0 ? t1 : i == 1 ? -t1 : i == 2 ? t2 : -t2
    p := cap_center + dir * radius
    sep := linalg.dot(plane_normal, p - plane_point)
    if sep >= margin do continue
    points[count] = {
      point       = p - plane_normal * (sep * 0.5),
      penetration = -sep,
      feature_id  = u32(i) | 0x00C10000,
    }
    count += 1
  }
  if count < 2 do return
  m.points = points
  m.count = count
}

@(private)
collide_box_cylinder :: proc(
  pos_box: [3]f32,
  rot_box: quaternion128,
  box: BoxCollider,
  pos_cyl: [3]f32,
  rot_cyl: quaternion128,
  cyl: CylinderCollider,
  margin: f32,
) -> (m: Manifold, hit: bool) {
  m = point_manifold(test_box_cylinder(pos_box, rot_box, box, pos_cyl, rot_cyl, cyl)) or_return
  // Cap resting on a box face: replace the point with penetrating rim samples
  // against the face plane through the box-side point.
  cylinder_cap_manifold(&m, pos_cyl, rot_cyl, cyl.radius, cyl.height, m.points[0].point, m.normal, margin)
  return m, true
}

@(private)
collide_cylinders :: proc(
  pos_a: [3]f32,
  rot_a: quaternion128,
  cyl_a: CylinderCollider,
  pos_b: [3]f32,
  rot_b: quaternion128,
  cyl_b: CylinderCollider,
  margin: f32,
) -> (m: Manifold, hit: bool) {
  axis_a := geometry.qy(rot_a)
  axis_b := geometry.qy(rot_b)
  parallel := math.abs(linalg.dot(axis_a, axis_b)) > 0.99
  if parallel {
    // Choose the smaller of radial vs axial penetration — stacked cylinders
    // must resolve axially (cap contact), not sideways.
    to_b := pos_b - pos_a
    axial_dist := linalg.dot(to_b, axis_a)
    radial_vec := to_b - axis_a * axial_dist
    radial_dist := linalg.length(radial_vec)
    radius_sum := cyl_a.radius + cyl_b.radius
    half_sum := (cyl_a.height + cyl_b.height) * 0.5
    radial_pen := radius_sum - radial_dist
    axial_pen := half_sum - math.abs(axial_dist)
    if radial_pen < -margin || axial_pen < -margin do return
    if axial_pen < radial_pen {
      normal := axial_dist > 0 ? axis_a : -axis_a
      r := min(cyl_a.radius, cyl_b.radius)
      cap_a := pos_a + normal * (cyl_a.height * 0.5)
      center := cap_a - normal * (axial_pen * 0.5)
      if radial_dist > math.F32_EPSILON {
        // Overlap circle centers differ; bias toward the overlap region
        center += radial_vec * 0.5
      }
      t1 := linalg.normalize(linalg.orthogonal(normal))
      t2 := linalg.cross(normal, t1)
      m.normal = normal
      m.count = 4
      for i in 0 ..< 4 {
        dir := i == 0 ? t1 : i == 1 ? -t1 : i == 2 ? t2 : -t2
        m.points[i] = {
          point       = center + dir * r,
          penetration = axial_pen,
          feature_id  = u32(i) | 0x00C20000,
        }
      }
      hit = true
      return
    }
    radial_dir := radial_dist > math.F32_EPSILON ? radial_vec / radial_dist : [3]f32{1, 0, 0}
    min_a := -cyl_a.height * 0.5
    max_a := cyl_a.height * 0.5
    min_b := axial_dist - cyl_b.height * 0.5
    max_b := axial_dist + cyl_b.height * 0.5
    lo := max(min_a, min_b)
    hi := min(max_a, max_b)
    contact_radial := pos_a + radial_dir * (cyl_a.radius - radial_pen * 0.5)
    m.normal = radial_dir
    m.count = 2
    m.points[0] = {
      point       = contact_radial + axis_a * lo,
      penetration = radial_pen,
      feature_id  = 0x00C30000,
    }
    m.points[1] = {
      point       = contact_radial + axis_a * hi,
      penetration = radial_pen,
      feature_id  = 0x00C30001,
    }
    hit = true
    return
  }
  point, normal, penetration, single_hit := test_cylinder_cylinder(
    pos_a, rot_a, cyl_a, pos_b, rot_b, cyl_b,
  )
  return point_manifold(point, normal, penetration, single_hit)
}

// margin: speculative distance — contacts are generated while shapes are
// still up to `margin` apart (penetration goes negative). The solver treats
// separated points as speculative (velocity clamp only, no push). Mirrored
// pairs reuse the B-vs-A routine and flip the normal.
@(private)
collide :: proc(
  collider_a: ^Collider,
  pos_a: [3]f32,
  rot_a: quaternion128,
  collider_b: ^Collider,
  pos_b: [3]f32,
  rot_b: quaternion128,
  margin: f32 = 0,
) -> (m: Manifold, hit: bool) {
  switch shape_a in collider_a {
  case SphereCollider:
    inflated := SphereCollider{radius = shape_a.radius + margin}
    switch shape_b in collider_b {
    case SphereCollider:
      return point_manifold(test_sphere_sphere(pos_a, inflated, pos_b, shape_b), margin)
    case BoxCollider:
      m, hit = point_manifold(test_box_sphere(pos_b, rot_b, shape_b, pos_a, inflated), margin)
      m.normal = -m.normal
      return
    case CylinderCollider:
      return point_manifold(test_sphere_cylinder(pos_a, inflated, pos_b, rot_b, shape_b), margin)
    }
  case BoxCollider:
    switch shape_b in collider_b {
    case SphereCollider:
      inflated := SphereCollider{radius = shape_b.radius + margin}
      return point_manifold(test_box_sphere(pos_a, rot_a, shape_a, pos_b, inflated), margin)
    case BoxCollider:
      return collide_boxes(pos_a, rot_a, shape_a, pos_b, rot_b, shape_b, margin)
    case CylinderCollider:
      return collide_box_cylinder(pos_a, rot_a, shape_a, pos_b, rot_b, shape_b, margin)
    }
  case CylinderCollider:
    switch shape_b in collider_b {
    case SphereCollider:
      inflated := SphereCollider{radius = shape_b.radius + margin}
      m, hit = point_manifold(test_sphere_cylinder(pos_b, inflated, pos_a, rot_a, shape_a), margin)
    case BoxCollider:
      m, hit = collide_box_cylinder(pos_b, rot_b, shape_b, pos_a, rot_a, shape_a, margin)
    case CylinderCollider:
      return collide_cylinders(pos_a, rot_a, shape_a, pos_b, rot_b, shape_b, margin)
    }
    m.normal = -m.normal
    return
  }
  return
}

@(private)
collide_bodies :: #force_inline proc(body_a, body_b: ^Body, margin: f32 = 0) -> (Manifold, bool) {
  return collide(
    &body_a.collider,
    body_a.position,
    body_a.rotation,
    &body_b.collider,
    body_b.position,
    body_b.rotation,
    margin,
  )
}

@(private)
narrowphase_pair :: proc(world: ^World, handle_a, handle_b: BodyHandle, out: ^[dynamic]Contact) {
  handle_a, handle_b := handle_a, handle_b
  body_a := body(world, handle_a) or_else nil
  body_b := body(world, handle_b) or_else nil
  if body_a == nil || body_b == nil do return
  if !is_dynamic(body_a) {
    if !is_dynamic(body_b) do return
    body_a, body_b = body_b, body_a
    handle_a, handle_b = handle_b, handle_a
  }
  if body_a.is_sleeping && (body_b.is_sleeping || !body_b.moving) do return
  if !bounding_spheres_intersect(
    body_a.cached_sphere_center, body_a.cached_sphere_radius + SPECULATIVE_DISTANCE,
    body_b.cached_sphere_center, body_b.cached_sphere_radius,
  ) {
    return
  }
  manifold, hit := collide_bodies(body_a, body_b, SPECULATIVE_DISTANCE)
  if !hit do return
  // Wake only sleepers: wake_up resets the sleep timer, so calling it on
  // every touching body would keep resting bodies awake forever.
  if body_a.is_sleeping do wake_up(body_a)
  b_dynamic := is_dynamic(body_b)
  if b_dynamic && body_b.is_sleeping do wake_up(body_b)
  contact := Contact {
    body_a      = handle_a,
    body_b      = handle_b,
    b_dynamic   = b_dynamic,
    normal      = manifold.normal,
    count       = manifold.count,
    restitution = mix_restitution(body_a.restitution, body_b.restitution),
    friction    = mix_friction(body_a.friction, body_b.friction),
  }
  for i in 0 ..< manifold.count {
    contact.points[i] = ContactPoint {
      point           = manifold.points[i].point,
      base_separation = -manifold.points[i].penetration,
      feature_id      = manifold.points[i].feature_id,
    }
  }
  if w, found := &world.prev_warmstart[collision_pair_hash(handle_a, handle_b)]; found {
    contact_apply_warmstart(&contact, w)
  }
  append(out, contact)
}

@(private = "file")
CollisionContext :: struct {
  dynamic_pairs: []geometry.BVHOverlapPair(BroadPhaseEntry),
  static_pairs:  []geometry.BVHCrossPair(BroadPhaseEntry, BroadPhaseEntry),
  contacts:      [][dynamic]Contact, // per task
}

// BVH tree-vs-tree traversal finds candidate pairs in O(N + K); narrowphase
// splits them across tasks, each appending to its own contact list, which
// are concatenated in task order.
@(private)
collision_detection :: proc(world: ^World) {
  dynamic_pairs := make([dynamic]geometry.BVHOverlapPair(BroadPhaseEntry), context.temp_allocator)
  static_pairs := make([dynamic]geometry.BVHCrossPair(BroadPhaseEntry, BroadPhaseEntry), context.temp_allocator)
  geometry.bvh_find_all_overlaps(&world.dynamic_bvh, &dynamic_pairs)
  geometry.bvh_find_cross_overlaps(&world.dynamic_bvh, &world.static_bvh, &static_pairs)
  ctx := CollisionContext {
    dynamic_pairs = dynamic_pairs[:],
    static_pairs  = static_pairs[:],
    contacts      = make([][dynamic]Contact, max(1, world.thread_count), context.temp_allocator),
  }
  parallel_for(world, len(dynamic_pairs) + len(static_pairs), &ctx, proc(world: ^World, ctx: rawptr, task, start, end: int) {
    ctx := (^CollisionContext)(ctx)
    out := &ctx.contacts[task]
    n_dyn := len(ctx.dynamic_pairs)
    #no_bounds_check for i in start ..< end {
      if i < n_dyn {
        pair := ctx.dynamic_pairs[i]
        narrowphase_pair(world, pair.a.handle, pair.b.handle, out)
      } else {
        pair := ctx.static_pairs[i - n_dyn]
        narrowphase_pair(world, pair.a.handle, pair.b.handle, out)
      }
    }
  })
  for c in ctx.contacts {
    append(&world.contacts, ..c[:])
    delete(c)
  }
}
