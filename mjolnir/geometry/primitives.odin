package geometry

import "core:math"
import "core:math/linalg"

Sphere :: struct {
  center: [3]f32,
  radius: f32,
}

ray_sphere_intersection :: proc "contextless" (
  ray: Ray,
  sphere: Sphere,
  max_t: f32 = F32_MAX,
) -> (
  hit: bool,
  t: f32,
) {
  oc := ray.origin - sphere.center
  a := linalg.dot(ray.direction, ray.direction)
  half_b := linalg.dot(oc, ray.direction)
  c := linalg.dot(oc, oc) - sphere.radius * sphere.radius
  discriminant := half_b * half_b - a * c
  if discriminant < 0 {
    return false, 0
  }
  sqrtd := math.sqrt(discriminant)
  root := (-half_b - sqrtd) / a
  if root < 0.001 || root > max_t {
    root = (-half_b + sqrtd) / a
    if root < 0.001 || root > max_t {
      return false, 0
    }
  }
  return true, root
}
