package geometry

import "core:math"
import "core:math/linalg"

// VEC_FORWARD, VEC_BACKWARD, VEC_UP, VEC_DOWN, VEC_LEFT and VEC_RIGHT are unit axes: forward +Z, up +Y, right +X.
VEC_FORWARD :: [3]f32{0.0, 0.0, 1.0}
VEC_BACKWARD :: [3]f32{0.0, 0.0, -1.0}
VEC_UP :: [3]f32{0.0, 1.0, 0.0}
VEC_DOWN :: [3]f32{0.0, -1.0, 0.0}
VEC_LEFT :: [3]f32{-1.0, 0.0, 0.0}
VEC_RIGHT :: [3]f32{1.0, 0.0, 0.0}
@(private)
F32_MIN :: -3.40282347E+38
@(private)
F32_MAX :: 3.40282347E+38

// vector_equal reports whether a and b differ by less than epsilon on every axis.
vector_equal :: proc "contextless" (
  a, b: [3]f32,
  epsilon: f32 = 0.0001,
) -> bool {
  diff := linalg.abs(a - b)
  return diff.x < epsilon && diff.y < epsilon && diff.z < epsilon
}

// calculate_polygon_min_extent_2d returns the polygon's smallest width on the XZ plane.
calculate_polygon_min_extent_2d :: proc(verts: [][3]f32) -> f32 {
  nverts := len(verts)
  if nverts < 3 do return 0
  min_dist := f32(1e30)
  for i in 0 ..< nverts {
    ni := (i + 1) % nverts
    p1 := verts[i]
    p2 := verts[ni]
    max_edge_dist := f32(0)
    for j in 0 ..< nverts {
      if j == i || j == ni do continue
      d, _ := point_segment_distance2_2d(verts[j], p1, p2)
      max_edge_dist = max(max_edge_dist, d)
    }
    min_dist = min(min_dist, max_edge_dist)
  }
  return math.sqrt(min_dist)
}

// point_segment_distance2_2d returns the squared distance from p to segment a-b in the XZ plane.
point_segment_distance2_2d :: proc "contextless" (
  p, a, b: [3]f32,
) -> (
  dist_sqr: f32,
  t: f32,
) {
  ab := b - a
  ap := p - a
  segment_length_sqr := linalg.length2(ab.xz)
  if segment_length_sqr > math.F32_EPSILON {
    t = linalg.saturate(linalg.dot(ap.xz, ab.xz) / segment_length_sqr)
  }
  pt := linalg.mix(a, b, t)
  return linalg.length2((p - pt).xz), t
}

// closest_point_on_segment_2d returns the point on segment a-b nearest p in the XZ plane.
closest_point_on_segment_2d :: proc "contextless" (p, a, b: [3]f32) -> [3]f32 {
  ab := b - a
  ap := p - a
  segment_length_sqr := linalg.length2(ab.xz)
  if segment_length_sqr < math.F32_EPSILON {
    return a
  }
  t := linalg.saturate(linalg.dot(ap.xz, ab.xz) / segment_length_sqr)
  return linalg.mix(a, b, t)
}

// ray_segment_intersect_2d tests a ray against a segment in the XZ plane.
ray_segment_intersect_2d :: proc "contextless" (
  ray_start, ray_dir, seg_start, seg_end: [3]f32,
) -> (
  t: f32,
  intersect: bool,
) {
  d := seg_end - seg_start
  denominator := linalg.cross(ray_dir.xz, d.xz)
  if math.abs(denominator) < 1e-6 {
    return
  }
  s := ray_start - seg_start
  t = linalg.cross(d.xz, s.xz) / denominator
  u := linalg.cross(ray_dir.xz, s.xz) / denominator
  intersect = t >= 0 && u >= 0 && u <= 1
  return
}

// segment_segment_intersect_2d reports whether segments p0-p1 and a-b cross on the XZ plane.
segment_segment_intersect_2d :: proc "contextless" (
  p0, p1, a, b: [3]f32,
) -> bool {
  segment := p1 - p0
  edge := b - a
  denominator := linalg.cross(segment.xz, edge.xz)
  if abs(denominator) < 1e-6 do return false
  ap := p0 - a
  t1 := linalg.cross(edge.xz, ap.xz) / denominator
  t2 := linalg.cross(segment.xz, ap.xz) / denominator
  return t1 >= 0.0 && t1 <= 1.0 && t2 >= 0.0 && t2 <= 1.0
}

// perpendicular_cross_2d returns the XZ cross product of (b - a) and (c - a).
perpendicular_cross_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
  return linalg.cross(b.xz - a.xz, c.xz - a.xz)
}

// point_in_triangle_2d reports whether p lies inside triangle abc in the XZ plane.
point_in_triangle_2d :: proc "contextless" (
  p, a, b, c: [3]f32,
  epsilon: f32 = 0.0,
) -> bool {
  cross1 := linalg.cross(b.xz - a.xz, p.xz - a.xz)
  cross2 := linalg.cross(c.xz - b.xz, p.xz - b.xz)
  cross3 := linalg.cross(a.xz - c.xz, p.xz - c.xz)
  return(
    (cross1 >= -epsilon && cross2 >= -epsilon && cross3 >= -epsilon) ||
    (cross1 <= epsilon && cross2 <= epsilon && cross3 <= epsilon) \
  )
}

// barycentric_2d returns the barycentric coordinates of p in triangle abc (XZ plane).
barycentric_2d :: proc "contextless" (p, a, b, c: [3]f32) -> [3]f32 {
  v0 := b.xz - a.xz
  v1 := c.xz - a.xz
  v2 := p.xz - a.xz
  d00 := linalg.dot(v0, v0)
  d01 := linalg.dot(v0, v1)
  d11 := linalg.dot(v1, v1)
  d20 := linalg.dot(v2, v0)
  d21 := linalg.dot(v2, v1)
  denom := d00 * d11 - d01 * d01
  if math.abs(denom) < math.F32_EPSILON {
    return {1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0}
  }
  v := (d11 * d20 - d01 * d21) / denom
  w := (d00 * d21 - d01 * d20) / denom
  u := 1.0 - v - w
  return {u, v, w}
}

// point_in_polygon_2d reports whether pt lies inside the polygon in the XZ plane.
point_in_polygon_2d :: proc "contextless" (
  pt: [3]f32,
  verts: [][3]f32,
) -> bool {
  c := false
  j := len(verts) - 1
  for i in 0 ..< len(verts) {
    vi := verts[i]
    vj := verts[j]
    // Use >= for one endpoint to handle edge case where ray passes through vertex
    if ((vi.z > pt.z) != (vj.z >= pt.z)) &&
       (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x) {
      c = !c
    }
    j = i
  }
  return c
}

// calc_tri_normal returns the normal of triangle v0 v1 v2.
calc_tri_normal :: proc "contextless" (v0, v1, v2: [3]f32) -> (norm: [3]f32) {
  e0 := v1 - v0
  e1 := v2 - v0
  norm = linalg.normalize(linalg.cross(e0, e1))
  return
}

// Direction utilities

// signed_triangle_area_2d returns the signed area of triangle abc in the XZ plane.
signed_triangle_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
  return linalg.cross(b.xz - a.xz, c.xz - a.xz) * 0.5
}

@(private)
aabb_disc_intersects :: proc "contextless" (
  aabb: Aabb,
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
) -> bool {
  closest := linalg.clamp(center, aabb.min, aabb.max)
  to_closest := closest - center
  dist_sq := linalg.dot(to_closest, to_closest)
  if dist_sq > radius * radius do return false
  dist_to_plane := linalg.dot(to_closest, normal)
  projected := closest - normal * dist_to_plane
  to_projected := projected - center
  projected_dist_sq := linalg.dot(to_projected, to_projected)
  return projected_dist_sq <= radius * radius
}

// point_segment_distance_sq returns the squared distance from pt to segment va-vb.
point_segment_distance_sq :: proc "contextless" (pt, va, vb: [3]f32) -> f32 {
  segment := vb - va
  to_pt := pt - va
  segment_length_sq := linalg.length2(segment)
  if segment_length_sq < math.F32_EPSILON {
    return linalg.length2(to_pt)
  }
  t := linalg.saturate(linalg.dot(to_pt, segment) / segment_length_sq)
  closest := va + segment * t
  return linalg.length2(pt - closest)
}

// point_to_triangle_distance_sq returns the squared distance from p to a triangle.
point_to_triangle_distance_sq :: proc "contextless" (
  p: [3]f32,
  a: [3]f32,
  b: [3]f32,
  c: [3]f32,
) -> f32 {
  ab := b - a
  ac := c - a
  ap := p - a
  d00 := linalg.dot(ab, ab)
  d01 := linalg.dot(ab, ac)
  d11 := linalg.dot(ac, ac)
  d20 := linalg.dot(ap, ab)
  d21 := linalg.dot(ap, ac)
  denom := d00 * d11 - d01 * d01
  if abs(denom) < 1e-10 {
    dist_a := linalg.length2(p - a)
    dist_b := linalg.length2(p - b)
    dist_c := linalg.length2(p - c)
    return min(dist_a, min(dist_b, dist_c))
  }
  inv_denom := 1.0 / denom
  u := (d11 * d20 - d01 * d21) * inv_denom
  v := (d00 * d21 - d01 * d20) * inv_denom
  if u >= 0 && v >= 0 && (u + v) <= 1 {
    closest := a + u * ab + v * ac
    return linalg.length2(p - closest)
  }
  min_dist_sq := f32(math.F32_MAX)
  t := linalg.saturate(linalg.dot(ap, ab) / d00)
  closest := a + t * ab
  min_dist_sq = min(min_dist_sq, linalg.length2(p - closest))
  t = linalg.saturate(linalg.dot(ap, ac) / d11)
  closest = a + t * ac
  min_dist_sq = min(min_dist_sq, linalg.length2(p - closest))
  bc := c - b
  bp := p - b
  t = linalg.saturate(linalg.dot(bp, bc) / linalg.dot(bc, bc))
  closest = b + t * bc
  min_dist_sq = min(min_dist_sq, linalg.length2(p - closest))
  return min_dist_sq
}

// safe_normalize normalizes v in place, leaving near-zero vectors untouched.
safe_normalize :: proc(v: ^[3]f32) {
  sq_mag := v.x * v.x + v.y * v.y + v.z * v.z
  if sq_mag <= math.F32_EPSILON do return
  inv_mag := 1.0 / math.sqrt(sq_mag)
  v.x *= inv_mag
  v.y *= inv_mag
  v.z *= inv_mag
}
