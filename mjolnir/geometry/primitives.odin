package geometry

import "core:math"
import "core:math/linalg"

// Sphere is a center and radius.
Sphere :: struct {
  center: [3]f32,
  radius: f32,
}

// ray_sphere_intersection returns t where ray hits sphere, at ray.origin + t * ray.direction
// with t <= max_t; false when it misses.
ray_sphere_intersection :: proc "contextless" (
  ray: Ray,
  sphere: Sphere,
  max_t: f32 = F32_MAX,
) -> (
  t: f32,
  hit: bool,
) {
  oc := ray.origin - sphere.center
  a := linalg.dot(ray.direction, ray.direction)
  half_b := linalg.dot(oc, ray.direction)
  c := linalg.dot(oc, oc) - sphere.radius * sphere.radius
  discriminant := half_b * half_b - a * c
  if discriminant < 0 {
    return 0, false
  }
  sqrtd := math.sqrt(discriminant)
  root := (-half_b - sqrtd) / a
  if root < 0.001 || root > max_t {
    root = (-half_b + sqrtd) / a
    if root < 0.001 || root > max_t {
      return 0, false
    }
  }
  return root, true
}

// ray_cylinder_intersection returns t where ray first hits the solid cylinder of `radius` around
// the Y axis, y within +-half_height, and the surface normal there; a ray starting inside hits
// at t = 0, facing back along it. False when it misses.
ray_cylinder_intersection :: proc "contextless" (
  ray: Ray,
  radius, half_height: f32,
) -> (
  t: f32,
  normal: [3]f32,
  hit: bool,
) {
  r2 := radius * radius
  if linalg.length2(ray.origin.xz) <= r2 && math.abs(ray.origin.y) <= half_height {
    return 0, -linalg.normalize(ray.direction), true
  }
  t = max(f32)
  if math.abs(ray.direction.y) > 1e-8 {
    for side in ([2]f32{-1, 1}) {
      s := (side * half_height - ray.origin.y) / ray.direction.y
      p := ray.origin + ray.direction * s
      if s >= 0 && s < t && linalg.length2(p.xz) <= r2 {
        t, normal, hit = s, {0, side, 0}, true
      }
    }
  }
  // Curved wall: |o.xz + s*d.xz|^2 = r^2, entering root
  a := linalg.length2(ray.direction.xz)
  if a > 1e-12 {
    b := linalg.dot(ray.origin.xz, ray.direction.xz)
    c := linalg.length2(ray.origin.xz) - r2
    disc := b * b - a * c
    if disc >= 0 {
      s := (-b - math.sqrt(disc)) / a
      p := ray.origin + ray.direction * s
      if s >= 0 && s < t && math.abs(p.y) <= half_height {
        t, normal, hit = s, {p.x / radius, 0, p.z / radius}, true
      }
    }
  }
  if !hit do t = 0
  return
}
