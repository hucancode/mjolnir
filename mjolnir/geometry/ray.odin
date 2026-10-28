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
