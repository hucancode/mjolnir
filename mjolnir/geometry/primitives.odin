package geometry

import "core:math"
import "core:math/linalg"

Triangle :: struct {
  v0, v1, v2: [3]f32,
}

Sphere :: struct {
  center: [3]f32,
  radius: f32,
}

Disc :: struct {
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
}

triangle_bounds :: proc "contextless" (tri: Triangle) -> Aabb {
  return Aabb {
    min = linalg.min(tri.v0, tri.v1, tri.v2),
    max = linalg.max(tri.v0, tri.v1, tri.v2),
  }
}

sphere_bounds :: proc "contextless" (sphere: Sphere) -> Aabb {
  return Aabb {
    min = sphere.center - sphere.radius,
    max = sphere.center + sphere.radius,
  }
}

disc_bounds :: proc "contextless" (disc: Disc) -> Aabb {
  tan1, tan2 := [3]f32{}, [3]f32{}
  if math.abs(disc.normal.y) > 0.9 {
    tan1 = linalg.normalize(
      linalg.cross(disc.normal, linalg.VECTOR3F32_X_AXIS),
    )
  } else {
    tan1 = linalg.normalize(
      linalg.cross(disc.normal, linalg.VECTOR3F32_Y_AXIS),
    )
  }
  tan2 = linalg.cross(disc.normal, tan1)
  ext1 := tan1 * disc.radius
  ext2 := tan2 * disc.radius
  p1 := disc.center + ext1
  p2 := disc.center - ext1
  p3 := disc.center + ext2
  p4 := disc.center - ext2
  return Aabb {
    min = linalg.min(linalg.min(p1, p2), linalg.min(p3, p4)),
    max = linalg.max(linalg.max(p1, p2), linalg.max(p3, p4)),
  }
}

ray_triangle_intersection :: proc "contextless" (
  ray: Ray,
  tri: Triangle,
  max_t: f32 = F32_MAX,
) -> (
  hit: bool,
  t: f32,
) {
  epsilon :: 1e-6
  edge1 := tri.v1 - tri.v0
  edge2 := tri.v2 - tri.v0
  h := linalg.cross(ray.direction, edge2)
  a := linalg.dot(edge1, h)
  if a > -epsilon && a < epsilon {
    return false, 0
  }
  f := 1.0 / a
  s := ray.origin - tri.v0
  u := f * linalg.dot(s, h)
  if u < 0.0 || u > 1.0 {
    return false, 0
  }
  q := linalg.cross(s, edge1)
  v := f * linalg.dot(ray.direction, q)
  if v < 0.0 || u + v > 1.0 {
    return false, 0
  }
  t = f * linalg.dot(edge2, q)
  if t > epsilon && t < max_t {
    return true, t
  }
  return false, 0
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

Primitive :: union {
  Triangle,
  Sphere,
  Disc,
}

primitive_bounds :: proc(prim: Primitive) -> Aabb {
  switch p in prim {
  case Triangle:
    return triangle_bounds(p)
  case Sphere:
    return sphere_bounds(p)
  case Disc:
    return disc_bounds(p)
  }
  return AABB_UNDEFINED
}
