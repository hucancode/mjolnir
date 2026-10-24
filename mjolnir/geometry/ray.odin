package geometry

import "core:math/linalg"

// Ray is an origin and a direction.
Ray :: struct {
  origin:    [3]f32,
  direction: [3]f32,
}

// ray_plane_intersection reports whether ray hits the plane through `point` facing `normal`
// (either side) within max_t, and the hit distance.
ray_plane_intersection :: proc "contextless" (
  ray: Ray,
  point, normal: [3]f32,
  max_t: f32 = F32_MAX,
) -> (
  hit: bool,
  t: f32,
) {
  facing := linalg.dot(ray.direction, normal)
  if abs(facing) < 1e-6 do return false, 0
  t = linalg.dot(point - ray.origin, normal) / facing
  return t >= 0 && t <= max_t, t
}
