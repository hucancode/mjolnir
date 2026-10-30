package geometry

import "core:math/linalg"

// Ray is an origin and a direction.
Ray :: struct {
  origin:    [3]f32,
  direction: [3]f32,
}

// ray_plane_intersection returns where ray hits the plane through `point` facing `normal`
// (either side), at ray.origin + t * ray.direction with 0 <= t <= max_t; false when it misses.
ray_plane_intersection :: proc "contextless" (
  ray: Ray,
  point, normal: [3]f32,
  max_t: f32 = F32_MAX,
) -> (
  hit_point: [3]f32,
  hit: bool,
) #optional_ok {
  facing := linalg.dot(ray.direction, normal)
  if abs(facing) < 1e-6 do return
  t := linalg.dot(point - ray.origin, normal) / facing
  if t < 0 || t > max_t do return
  return ray.origin + ray.direction * t, true
}

// ray_triangle_intersection returns t where ray crosses triangle (v0, v1, v2) from either side,
// hitting at ray.origin + t * ray.direction; false when it misses or t <= 0.
ray_triangle_intersection :: proc "contextless" (ray: Ray, v0, v1, v2: [3]f32) -> (t: f32, hit: bool) {
  origin, dir := ray.origin, ray.direction
  e1 := v1 - v0
  e2 := v2 - v0
  h := linalg.cross(dir, e2)
  a := linalg.dot(e1, h)
  if abs(a) < 1e-8 do return 0, false
  f := 1 / a
  s := origin - v0
  u := f * linalg.dot(s, h)
  if u < 0 || u > 1 do return 0, false
  q := linalg.cross(s, e1)
  v := f * linalg.dot(dir, q)
  if v < 0 || u + v > 1 do return 0, false
  t = f * linalg.dot(e2, q)
  return t, t > 0
}
