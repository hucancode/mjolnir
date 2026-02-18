package geometry

import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

VEC_FORWARD :: [3]f32{0.0, 0.0, 1.0}
VEC_BACKWARD :: [3]f32{0.0, 0.0, -1.0}
VEC_UP :: [3]f32{0.0, 1.0, 0.0}
VEC_DOWN :: [3]f32{0.0, -1.0, 0.0}
VEC_LEFT :: [3]f32{-1.0, 0.0, 0.0}
VEC_RIGHT :: [3]f32{1.0, 0.0, 0.0}
F32_MIN :: -3.40282347E+38
F32_MAX :: 3.40282347E+38

vector_equal :: proc "contextless" (
  a, b: [3]f32,
  epsilon: f32 = 0.0001,
) -> bool {
  diff := linalg.abs(a - b)
  return diff.x < epsilon && diff.y < epsilon && diff.z < epsilon
}

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

// Calculate squared distance from point to line segment in 2D (XZ plane)
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

closest_point_on_segment :: proc "contextless" (p, a, b: [3]f32) -> [3]f32 {
  ab := b - a
  ap := p - a
  segment_length_sq := linalg.length2(ab)
  if segment_length_sq < math.F32_EPSILON {
    return a
  }
  t := linalg.saturate(linalg.dot(ap, ab) / segment_length_sq)
  return linalg.mix(a, b, t)
}

// Find closest point on line segment in 2D (XZ plane)
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

// Ray-circle intersection test (2D XZ plane)
ray_circle_intersect_2d :: proc "contextless" (
  pos, vel: [3]f32,
  radius: f32,
) -> (
  t: f32,
  intersect: bool,
) {
  a := linalg.length2(vel.xz)
  if a < 1e-6 do return // No movement
  b := 2.0 * linalg.dot(pos.xz, vel.xz)
  c := linalg.length2(pos.xz) - radius * radius
  discriminant := b * b - 4 * a * c
  if discriminant < 0 do return // No intersection
  sqrt_disc := math.sqrt(discriminant)
  t1 := (-b - sqrt_disc) / (2 * a)
  t2 := (-b + sqrt_disc) / (2 * a)
  if t1 >= 0 do return t1, true
  if t2 >= 0 do return t2, true
  return
}

// Ray-segment intersection test (2D XZ plane)
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

// Calculate perpendicular cross product in 2D (XZ plane)
perpendicular_cross_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
  return linalg.cross(b.xz - a.xz, c.xz - a.xz)
}

// Check if point is inside triangle in 2D (XZ plane)
point_in_triangle_2d :: proc "contextless" (
  p, a, b, c: [3]f32,
  epsilon: f32 = 0.0,
) -> bool {
  // Use edge testing method - point is inside if it's on the same side of all edges
  cross1 := linalg.cross(b.xz - a.xz, p.xz - a.xz)
  cross2 := linalg.cross(c.xz - b.xz, p.xz - b.xz)
  cross3 := linalg.cross(a.xz - c.xz, p.xz - c.xz)
  // Check if all cross products have the same sign
  return(
    (cross1 >= -epsilon && cross2 >= -epsilon && cross3 >= -epsilon) ||
    (cross1 <= epsilon && cross2 <= epsilon && cross3 <= epsilon) \
  )
}

// Calculate barycentric coordinates for a point in a triangle (2D XZ plane)
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

// Point in polygon test (2D XZ plane)
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

// Calculate triangle normal
calc_tri_normal :: proc "contextless" (v0, v1, v2: [3]f32) -> (norm: [3]f32) {
  e0 := v1 - v0
  e1 := v2 - v0
  norm = linalg.normalize(linalg.cross(e0, e1))
  return
}

// Calculate signed area of triangle formed by three 2D points
// Positive area = counter-clockwise, negative = clockwise
// This is the 2D cross product of vectors (b-a) and (c-a)
area2 :: proc "contextless" (a, b, c: [2]i32) -> i32 {
  return linalg.cross(b - a, c - a)
}

// Check if point c is to the left or on the directed line from a to b
left_on :: proc "contextless" (a, b, c: [2]i32) -> bool {
  return area2(a, b, c) <= 0
}

// Check if point p is inside the cone formed by three consecutive vertices a0, a1, a2
// a1 is the apex of the cone
in_cone :: proc "contextless" (a0, a1, a2, p: [2]i32) -> bool {
  // If a1 is a convex vertex (a2 is left or on the line from a0 to a1)
  if left_on(a0, a1, a2) {
    // p must be left of a1->p->a0 AND left of p->a1->a2
    return left(a1, p, a0) && left(p, a1, a2)
  }
  // else a1 is reflex
  // p must NOT be (left-or-on a1->p->a2 AND left-or-on p->a1->a0)
  return !(left_on(a1, p, a2) && left_on(p, a1, a0))
}

// Check if point c is to the left of the directed line from a to b
left :: proc "contextless" (a, b, c: [2]i32) -> bool {
  return area2(a, b, c) < 0
}

// Check if point p lies on the line segment from a to b
between :: proc "contextless" (a, b, p: [2]i32) -> bool {
  if area2(a, b, p) != 0 {
    return false // Not collinear
  }
  // If ab not vertical, check betweenness on x; else on y
  if a.x != b.x {
    return ((a.x <= p.x) && (p.x <= b.x)) || ((a.x >= p.x) && (p.x >= b.x))
  } else {
    return ((a.y <= p.y) && (p.y <= b.y)) || ((a.y >= p.y) && (p.y >= b.y))
  }
}

// Check if line segments ab and cd intersect properly (at a point interior to both segments)
intersect_prop :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
  // Eliminate improper cases (endpoints touching)
  if area2(a, b, c) == 0 ||
     area2(a, b, d) == 0 ||
     area2(c, d, a) == 0 ||
     area2(c, d, b) == 0 {
    return false
  }
  // Check if c and d are on opposite sides of ab, and a and b are on opposite sides of cd
  return (left(a, b, c) != left(a, b, d)) && (left(c, d, a) != left(c, d, b))
}

// Check if line segments ab and cd intersect (properly or improperly)
intersect :: proc "contextless" (a, b, c, d: [2]i32) -> bool {
  if intersect_prop(a, b, c, d) {
    return true
  }
  // Check if any endpoint lies on the other segment
  return(
    between(a, b, c) ||
    between(a, b, d) ||
    between(c, d, a) ||
    between(c, d, b) \
  )
}

// Direction utilities

// Get next direction in clockwise order (0=+X, 1=+Z, 2=-X, 3=-Z)
next_dir :: proc "contextless" (dir: int) -> int {
  return (dir + 1) & 0x3
}

// Get previous direction in clockwise order
prev_dir :: proc "contextless" (dir: int) -> int {
  return (dir + 3) & 0x3
}

// Calculate area of triangle in 2D (XZ plane)
signed_triangle_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
  return linalg.cross(b.xz - a.xz, c.xz - a.xz) * 0.5
}

// Calculate area of triangle in 2D (XZ plane)
triangle_area_2d :: proc "contextless" (a, b, c: [3]f32) -> f32 {
  return math.abs(signed_triangle_area_2d(a, b, c))
}

// Intersection test between ray/segment and triangle
intersect_segment_triangle :: proc "contextless" (
  sp, sq: [3]f32,
  a, b, c: [3]f32,
) -> (
  hit: bool,
  t: f32,
) {
  ab := b - a
  ac := c - a
  qp := sp - sq
  // Compute triangle normal
  norm := linalg.cross(ab, ac)
  // Compute denominator
  d := linalg.dot(qp, norm)
  if math.abs(d) < math.F32_EPSILON {
    return false, 0
  }
  // Compute intersection t value
  ap := sp - a
  t = linalg.dot(ap, norm) / d
  if t < 0 || t > 1 {
    return false, 0
  }
  // Compute barycentric coordinates
  e := linalg.cross(qp, ap)
  v := linalg.dot(ac, e) / d
  if v < 0 || v > 1 {
    return false, 0
  }
  w := -linalg.dot(ab, e) / d
  if w < 0 || v + w > 1 {
    return false, 0
  }
  return true, t
}

// Find closest point on triangle in 3D
closest_point_on_triangle :: proc "contextless" (
  p, a, b, c: [3]f32,
) -> [3]f32 {
  // Check if P in vertex region outside A
  ab := b - a
  ac := c - a
  ap := p - a
  d1 := linalg.dot(ab, ap)
  d2 := linalg.dot(ac, ap)
  if d1 <= 0 && d2 <= 0 {
    return a
  }
  // Check if P in vertex region outside B
  bp := p - b
  d3 := linalg.dot(ab, bp)
  d4 := linalg.dot(ac, bp)
  if d3 >= 0 && d4 <= d3 {
    return b
  }
  // Check if P in edge region of AB
  vc := d1 * d4 - d3 * d2
  if vc <= 0 && d1 >= 0 && d3 <= 0 {
    v := d1 / (d1 - d3)
    return a + v * ab
  }
  // Check if P in vertex region outside C
  cp := p - c
  d5 := linalg.dot(ab, cp)
  d6 := linalg.dot(ac, cp)
  if d6 >= 0 && d5 <= d6 {
    return c
  }
  // Check if P in edge region of AC
  vb := d5 * d2 - d1 * d6
  if vb <= 0 && d2 >= 0 && d6 <= 0 {
    w := d2 / (d2 - d6)
    return a + w * ac
  }
  // Check if P in edge region of BC
  va := d3 * d6 - d5 * d4
  if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
    w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
    return b + w * (c - b)
  }
  // P inside face region
  denom := 1 / (va + vb + vc)
  v := vb * denom
  w := vc * denom
  return a + ab * v + ac * w
}

// Calculate polygon normal using Newell's method
calc_poly_normal :: proc "contextless" (verts: [][3]f32) -> [3]f32 {
  normal := [3]f32{0, 0, 0}
  for i in 0 ..< len(verts) {
    v0 := verts[i]
    v1 := verts[(i + 1) % len(verts)]
    normal.x += (v0.y - v1.y) * (v0.z + v1.z)
    normal.y += (v0.z - v1.z) * (v0.x + v1.x)
    normal.z += (v0.x - v1.x) * (v0.y + v1.y)
  }
  // Normalize the result
  if linalg.length2(normal) > math.F32_EPSILON * math.F32_EPSILON {
    normal = linalg.normalize(normal)
  }
  return normal
}

// Calculate polygon area using cross products (2D XZ plane)
poly_area_2d :: proc "contextless" (verts: [][3]f32) -> f32 {
  area: f32 = 0
  for i in 0 ..< len(verts) {
    a := verts[i].xz
    b := verts[(i + 1) % len(verts)].xz
    area += linalg.cross(a, b)
  }
  return area * 0.5
}

// Check if two line segments intersect in 2D (XZ plane)
intersect_segments_2d :: proc "contextless" (
  ap, aq, bp, bq: [3]f32,
) -> (
  hit: bool,
  s: f32,
  t: f32,
) {
  a_dir := aq.xz - ap.xz
  b_dir := bq.xz - bp.xz
  diff := bp.xz - ap.xz
  cross := linalg.cross(a_dir, b_dir)
  if math.abs(cross) < math.F32_EPSILON {
    return false, 0, 0
  }
  s = linalg.cross(diff, b_dir) / cross
  t = linalg.cross(diff, a_dir) / cross
  return s >= 0 && s <= 1 && t >= 0 && t <= 1, s, t
}

// Check if circle overlaps with line segment (2D XZ plane)
overlap_circle_segment :: proc "contextless" (
  center: [3]f32,
  radius: f32,
  p, q: [3]f32,
) -> bool {
  dist_sqr, _ := point_segment_distance2_2d(center, p, q)
  return dist_sqr <= radius * radius
}

ray_primitive_intersection :: proc(
  ray: Ray,
  prim: Primitive,
  max_t: f32 = F32_MAX,
) -> (
  hit: bool,
  t: f32,
) {
  switch p in prim {
  case Triangle:
    return ray_triangle_intersection(ray, p, max_t)
  case Sphere:
    return ray_sphere_intersection(ray, p, max_t)
  case Disc:
    return false, 0
  }
  return false, 0
}

sphere_sphere_intersection :: proc "contextless" (
  s1: Sphere,
  s2: Sphere,
) -> bool {
  d := linalg.length(s1.center - s2.center)
  return d <= (s1.radius + s2.radius)
}

sphere_triangle_intersection :: proc "contextless" (
  sphere: Sphere,
  tri: Triangle,
) -> bool {
  closest := closest_point_on_triangle_struct(sphere.center, tri)
  d := linalg.length(sphere.center - closest)
  return d <= sphere.radius
}

sphere_disc_intersection :: proc "contextless" (
  sphere: Sphere,
  disc: Disc,
) -> bool {
  n_len_sq := linalg.length2(disc.normal)
  if n_len_sq <= math.F32_EPSILON * math.F32_EPSILON do return false
  n := disc.normal / math.sqrt(n_len_sq)
  to_center := sphere.center - disc.center
  dist_to_plane := linalg.dot(to_center, n)
  projected := sphere.center - n * dist_to_plane
  radial := projected - disc.center
  radial_len_sq := linalg.length2(radial)
  closest := projected
  radius_sq := disc.radius * disc.radius
  if radial_len_sq > radius_sq && radial_len_sq > math.F32_EPSILON {
    closest = disc.center + radial * (disc.radius / math.sqrt(radial_len_sq))
  }
  return(
    linalg.length2(sphere.center - closest) <=
    sphere.radius * sphere.radius \
  )
}

triangle_disc_intersection :: proc "contextless" (
  tri: Triangle,
  disc: Disc,
) -> bool {
  n_len_sq := linalg.length2(disc.normal)
  if n_len_sq <= math.F32_EPSILON * math.F32_EPSILON do return false
  n := disc.normal / math.sqrt(n_len_sq)
  epsilon :: 1e-6
  d0 := linalg.dot(tri.v0 - disc.center, n)
  d1 := linalg.dot(tri.v1 - disc.center, n)
  d2 := linalg.dot(tri.v2 - disc.center, n)
  radius_sq := disc.radius * disc.radius
  // Coplanar case reduces to point-to-triangle distance in disc plane.
  if math.abs(d0) <= epsilon &&
     math.abs(d1) <= epsilon &&
     math.abs(d2) <= epsilon {
    closest := closest_point_on_triangle_struct(disc.center, tri)
    return linalg.length2(closest - disc.center) <= radius_sq
  }
  // Triangle is fully on one side of the disc plane.
  if (d0 > epsilon && d1 > epsilon && d2 > epsilon) ||
     (d0 < -epsilon && d1 < -epsilon && d2 < -epsilon) {
    return false
  }
  points: [6][3]f32
  count := 0
  if math.abs(d0) <= epsilon {
    points[count] = tri.v0
    count += 1
  }
  if d0 * d1 < 0 {
    t := d0 / (d0 - d1)
    points[count] = tri.v0 + (tri.v1 - tri.v0) * t
    count += 1
  }
  if math.abs(d1) <= epsilon {
    points[count] = tri.v1
    count += 1
  }
  if d1 * d2 < 0 {
    t := d1 / (d1 - d2)
    points[count] = tri.v1 + (tri.v2 - tri.v1) * t
    count += 1
  }
  if math.abs(d2) <= epsilon {
    points[count] = tri.v2
    count += 1
  }
  if d2 * d0 < 0 {
    t := d2 / (d2 - d0)
    points[count] = tri.v2 + (tri.v0 - tri.v2) * t
    count += 1
  }
  if count == 0 do return false
  for i in 0 ..< count {
    if linalg.length2(points[i] - disc.center) <= radius_sq {
      return true
    }
  }
  if count >= 2 {
    for i in 0 ..< count - 1 {
      for j in i + 1 ..< count {
        closest := closest_point_on_segment(disc.center, points[i], points[j])
        if linalg.length2(closest - disc.center) <= radius_sq {
          return true
        }
      }
    }
  }
  return false
}

@(private)
closest_point_on_triangle_struct :: proc "contextless" (
  p: [3]f32,
  tri: Triangle,
) -> [3]f32 {
  ab := tri.v1 - tri.v0
  ac := tri.v2 - tri.v0
  ap := p - tri.v0
  d1 := linalg.dot(ab, ap)
  d2 := linalg.dot(ac, ap)
  if d1 <= 0.0 && d2 <= 0.0 do return tri.v0
  bp := p - tri.v1
  d3 := linalg.dot(ab, bp)
  d4 := linalg.dot(ac, bp)
  if d3 >= 0.0 && d4 <= d3 do return tri.v1
  vc := d1 * d4 - d3 * d2
  if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 {
    v := d1 / (d1 - d3)
    return tri.v0 + v * ab
  }
  cp := p - tri.v2
  d5 := linalg.dot(ab, cp)
  d6 := linalg.dot(ac, cp)
  if d6 >= 0.0 && d5 <= d6 do return tri.v2
  vb := d5 * d2 - d1 * d6
  if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 {
    w := d2 / (d2 - d6)
    return tri.v0 + w * ac
  }
  va := d3 * d6 - d5 * d4
  if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0 {
    w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
    return tri.v1 + w * (tri.v2 - tri.v1)
  }
  denom := 1.0 / (va + vb + vc)
  v := vb * denom
  w := vc * denom
  return tri.v0 + ab * v + ac * w
}

sphere_primitive_intersection :: proc(
  sphere: Sphere,
  prim: Primitive,
) -> bool {
  switch p in prim {
  case Triangle:
    return sphere_triangle_intersection(sphere, p)
  case Sphere:
    return sphere_sphere_intersection(sphere, p)
  case Disc:
    return sphere_disc_intersection(sphere, p)
  }
  return false
}

disc_primitive_intersection :: proc(disc: Disc, prim: Primitive) -> bool {
  switch p in prim {
  case Triangle:
    return triangle_disc_intersection(p, disc)
  case Sphere:
    return sphere_disc_intersection(p, disc)
  case Disc:
    return false
  }
  return false
}

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

point_in_disc :: proc(point: [3]f32, disc: Disc) -> bool {
  to_point := point - disc.center
  dist_to_plane := linalg.dot(to_point, disc.normal)
  epsilon :: 1e-6
  if math.abs(dist_to_plane) > epsilon do return false
  projected := point - disc.normal * dist_to_plane
  to_projected := projected - disc.center
  dist_sq := linalg.dot(to_projected, to_projected)
  return dist_sq <= disc.radius * disc.radius
}

// Check if two bounding boxes overlap in 2D (XZ plane)
overlap_bounds_2d :: proc "contextless" (
  amin, amax, bmin, bmax: [3]f32,
) -> bool {
  return(
    amin.x <= bmax.x &&
    amax.x >= bmin.x &&
    amin.z <= bmax.z &&
    amax.z >= bmin.z \
  )
}

// Calculate circumcircle of a triangle
// Returns center and radius squared
// Based on C++ circumCircle from RecastMeshDetail.cpp
circum_circle :: proc "contextless" (
  a, b, c: [3]f32,
) -> (
  center: [2]f32,
  r_sq: f32,
  valid: bool,
) {
  EPS :: 1e-6
  ab := b - a
  ac := c - a
  cross := linalg.cross(ac.xz, ab.xz)
  if abs(cross) < EPS {
    valid = false
    return
  }
  len_ab_sq := linalg.length2(ab.xz)
  len_ac_sq := linalg.length2(ac.xz)
  inv_cross := 1.0 / (2.0 * cross)
  ux := (ac.z * len_ab_sq - ab.z * len_ac_sq) * inv_cross
  uy := (ab.x * len_ac_sq - ac.x * len_ab_sq) * inv_cross
  center.x = a.x + ux
  center.y = a.z + uy
  r_sq = ux * ux + uy * uy
  valid = true
  return
}

// Check if a point is inside the circumcircle of a triangle
in_circumcircle :: proc "contextless" (p, a, b, c: [3]f32) -> bool {
  center, r_sq := circum_circle(a, b, c) or_return
  return linalg.length2(p.xz - center) <= r_sq
}

// Distance squared from point to line segment in 3D
// Returns the squared distance for performance
point_segment_distance_sq :: proc "contextless" (pt, va, vb: [3]f32) -> f32 {
  segment := vb - va
  to_pt := pt - va
  segment_length_sq := linalg.length2(segment)
  if segment_length_sq < math.F32_EPSILON {
    return linalg.length2(to_pt)
  }
  // Project point onto segment
  t := linalg.saturate(linalg.dot(to_pt, segment) / segment_length_sq)
  closest := va + segment * t
  return linalg.length2(pt - closest)
}

// Distance from point to line segment in 3D
point_segment_distance :: proc "contextless" (pt, va, vb: [3]f32) -> f32 {
  return math.sqrt(point_segment_distance_sq(pt, va, vb))
}

// Distance squared from point to triangle in 3D
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

// Distance from point to triangle in 3D
point_to_triangle_distance :: proc "contextless" (
  p: [3]f32,
  a: [3]f32,
  b: [3]f32,
  c: [3]f32,
) -> f32 {
  return math.sqrt(point_to_triangle_distance_sq(p, a, b, c))
}

// returns closest point on segment A, closest point on segment B, and parametric values s and t
segment_segment_closest_points :: proc "contextless" (
  a_start, a_end: [3]f32,
  b_start, b_end: [3]f32,
) -> (
  point_on_a: [3]f32,
  point_on_b: [3]f32,
  s: f32,
  t: f32,
) {
  d1 := a_end - a_start
  d2 := b_end - b_start
  r := a_start - b_start
  a := linalg.length2(d1)
  e := linalg.length2(d2)
  f := linalg.dot(d2, r)
  if a <= math.F32_EPSILON && e <= math.F32_EPSILON {
    // Both segments are points
    s, t = 0, 0
    point_on_a = a_start
    point_on_b = b_start
    return
  }
  if a <= math.F32_EPSILON {
    // First segment is a point
    s = 0
    t = linalg.saturate(f / e)
    point_on_a = a_start
    point_on_b = b_start + d2 * t
    return
  }

  c := linalg.dot(d1, r)
  if e <= math.F32_EPSILON {
    // Second segment is a point
    s = linalg.saturate(-c / a)
    t = 0
    point_on_a = a_start + d1 * s
    point_on_b = b_start
    return
  }
  // general case: both segments are non-degenerate
  b := linalg.dot(d1, d2)
  denom := a * e - b * b
  // compute s for the closest point on segment A
  if denom != 0 {
    s = linalg.saturate((b * f - c * e) / denom)
  } else {
    s = 0
  }
  // compute t for the closest point on segment B
  t = (b * s + f) / e
  // clamp t to [0,1] and recompute s if necessary
  if t < 0 {
    s = linalg.saturate(-c / a)
    t = 0
  } else if t > 1 {
    s = linalg.saturate((b - c) / a)
    t = 1
  }
  point_on_a = a_start + d1 * s
  point_on_b = b_start + d2 * t
  return
}

// Distance from point to polygon boundary with inside/outside test
// Returns negative distance if point is inside, positive if outside
// Based on C++ distToPoly from RecastMeshDetail.cpp
point_polygon_distance :: proc(pt: [3]f32, vertices: [][3]f32) -> f32 {
  if len(vertices) < 3 do return math.F32_MAX
  min_dist_sq := f32(math.F32_MAX)
  inside := false
  for i in 0 ..< len(vertices) {
    j := (i + len(vertices) - 1) % len(vertices)
    vi := vertices[i]
    vj := vertices[j]
    // Point-in-polygon test using ray casting (XZ plane)
    if ((vi.z > pt.z) != (vj.z > pt.z)) &&
       (pt.x < (vj.x - vi.x) * (pt.z - vi.z) / (vj.z - vi.z) + vi.x) {
      inside = !inside
    }
    // Find minimum distance to edge
    dist_sq, _ := point_segment_distance2_2d(pt, vi, vj)
    min_dist_sq = min(min_dist_sq, dist_sq)
  }
  min_dist := math.sqrt(min_dist_sq)
  return inside ? -min_dist : min_dist
}

// Distance from point to triangle mesh
// Based on C++ distToTriMesh from RecastMeshDetail.cpp
point_triangle_mesh_distance :: proc(
  p: [3]f32,
  verts: [][3]f32,
  tris: [][3]u8,
) -> f32 {
  min_dist := f32(math.F32_MAX)
  for tri in tris {
    va := verts[tri[0]]
    vb := verts[tri[1]]
    vc := verts[tri[2]]
    // Project point onto triangle plane
    n := linalg.cross(vb - va, vc - va)
    if linalg.length2(n) < math.F32_EPSILON do continue
    n = linalg.normalize(n)
    plane_dist := linalg.dot(p - va, n)
    projected := p - n * plane_dist
    // Check if projected point is inside triangle using barycentric coordinates
    v0 := vc - va
    v1 := vb - va
    v2 := projected - va
    dot00 := linalg.dot(v0, v0)
    dot01 := linalg.dot(v0, v1)
    dot02 := linalg.dot(v0, v2)
    dot11 := linalg.dot(v1, v1)
    dot12 := linalg.dot(v1, v2)
    denom := dot00 * dot11 - dot01 * dot01
    if abs(denom) < math.F32_EPSILON do continue
    inv_denom := 1.0 / denom
    u := (dot11 * dot02 - dot01 * dot12) * inv_denom
    v := (dot00 * dot12 - dot01 * dot02) * inv_denom
    if (u >= 0) && (v >= 0) && (u + v <= 1) {
      return abs(plane_dist)
    }
    // Point is outside triangle, find distance to edges
    d0 := point_segment_distance(p, va, vb)
    d1 := point_segment_distance(p, vb, vc)
    d2 := point_segment_distance(p, vc, va)
    min_dist = min(min_dist, d0, d1, d2)
  }
  return min_dist
}

safe_normalize :: proc(v: ^[3]f32) {
  sq_mag := v.x * v.x + v.y * v.y + v.z * v.z
  if sq_mag <= math.F32_EPSILON do return
  inv_mag := 1.0 / math.sqrt(sq_mag)
  v.x *= inv_mag
  v.y *= inv_mag
  v.z *= inv_mag
}

// Offset polygon - creates an inset/outset polygon with proper miter/bevel handling
// Returns the offset vertices and success status
offset_poly_2d :: proc(
  verts: [][3]f32,
  offset: f32,
) -> (
  out_verts: [dynamic][3]f32,
  ok: bool,
) {
  // Defines the limit at which a miter becomes a bevel
  // Similar in behavior to https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/stroke-miterlimit
  MITER_LIMIT :: 1.20
  num_verts := len(verts)
  if num_verts < 3 do return nil, false
  // First pass: calculate how many vertices we'll need
  estimated_verts := num_verts * 2 // Conservative estimate for beveling
  out_verts = make([dynamic][3]f32, 0, estimated_verts)
  for vert_index in 0 ..< num_verts {
    // Grab three vertices of the polygon
    vert_index_a := (vert_index + num_verts - 1) % num_verts
    vert_index_b := vert_index
    vert_index_c := (vert_index + 1) % num_verts
    vert_a := verts[vert_index_a]
    vert_b := verts[vert_index_b]
    vert_c := verts[vert_index_c]
    // From A to B on the x/z plane
    prev_segment_dir: [3]f32
    prev_segment_dir.x = vert_b.x - vert_a.x
    prev_segment_dir.y = 0 // Squash onto x/z plane
    prev_segment_dir.z = vert_b.z - vert_a.z
    safe_normalize(&prev_segment_dir)
    // From B to C on the x/z plane
    curr_segment_dir: [3]f32
    curr_segment_dir.x = vert_c.x - vert_b.x
    curr_segment_dir.y = 0 // Squash onto x/z plane
    curr_segment_dir.z = vert_c.z - vert_b.z
    safe_normalize(&curr_segment_dir)
    // The y component of the cross product of the two normalized segment directions
    // The X and Z components of the cross product are both zero because the two
    // segment direction vectors fall within the x/z plane
    cross := linalg.cross(curr_segment_dir.xz, prev_segment_dir.xz)
    // CCW perpendicular vector to AB. The segment normal
    prev_segment_norm_x := -prev_segment_dir.z
    prev_segment_norm_z := prev_segment_dir.x
    // CCW perpendicular vector to BC. The segment normal
    curr_segment_norm_x := -curr_segment_dir.z
    curr_segment_norm_z := curr_segment_dir.x
    // Average the two segment normals to get the proportional miter offset for B
    // This isn't normalized because it's defining the distance and direction the corner will need to be
    // adjusted proportionally to the edge offsets to properly miter the adjoining edges
    corner_miter_x := (prev_segment_norm_x + curr_segment_norm_x) * 0.5
    corner_miter_z := (prev_segment_norm_z + curr_segment_norm_z) * 0.5
    corner_miter_sq_mag :=
      corner_miter_x * corner_miter_x + corner_miter_z * corner_miter_z
    // If the magnitude of the segment normal average is less than about .69444,
    // the corner is an acute enough angle that the result should be beveled
    bevel := corner_miter_sq_mag * MITER_LIMIT * MITER_LIMIT < 1.0
    // Scale the corner miter so it's proportional to how much the corner should be offset compared to the edges
    if corner_miter_sq_mag > math.F32_EPSILON {
      scale := 1.0 / corner_miter_sq_mag
      corner_miter_x *= scale
      corner_miter_z *= scale
    }
    if bevel && cross < 0.0 {   // If the corner is convex and an acute enough angle, generate a bevel
      // Generate two bevel vertices at distances from B proportional to the angle between the two segments
      // Move each bevel vertex out proportional to the given offset
      d :=
        (1.0 -
          (prev_segment_dir.x * curr_segment_dir.x +
              prev_segment_dir.z * curr_segment_dir.z)) *
        0.5
      append(
        &out_verts,
        [3]f32 {
          vert_b.x + (-prev_segment_norm_x + prev_segment_dir.x * d) * offset,
          vert_b.y,
          vert_b.z + (-prev_segment_norm_z + prev_segment_dir.z * d) * offset,
        },
      )
      append(
        &out_verts,
        [3]f32 {
          vert_b.x + (-curr_segment_norm_x - curr_segment_dir.x * d) * offset,
          vert_b.y,
          vert_b.z + (-curr_segment_norm_z - curr_segment_dir.z * d) * offset,
        },
      )
    } else {
      // Move B along the miter direction by the specified offset
      append(
        &out_verts,
        [3]f32 {
          vert_b.x - corner_miter_x * offset,
          vert_b.y,
          vert_b.z - corner_miter_z * offset,
        },
      )
    }
  }
  // Allocate final output with the exact size needed
  if len(out_verts) == 0 {
    delete(out_verts)
    return nil, false
  }
  return out_verts, true
}

// Calculate signed area of 2D contour (positive = counter-clockwise, negative = clockwise)
calculate_contour_area :: proc(verts: [][4]i32) -> i32 {
  if len(verts) < 3 do return 0 // Need at least 3 vertices
  nverts := len(verts)
  area: i32 = 0
  j := nverts - 1
  for i in 0 ..< nverts {
    vi := verts[i]
    vj := verts[j]
    area += vi.x * vj.z - vj.x * vi.z
    j = i
  }
  return (area + 1) / 2 // Round and return signed area
}
