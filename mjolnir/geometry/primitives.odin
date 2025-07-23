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

triangle_bounds :: proc(tri: Triangle) -> Aabb {
  return Aabb{
    min = linalg.min(tri.v0, tri.v1, tri.v2),
    max = linalg.max(tri.v0, tri.v1, tri.v2),
  }
}

sphere_bounds :: proc(sphere: Sphere) -> Aabb {
  r := [3]f32{sphere.radius, sphere.radius, sphere.radius}
  return Aabb{
    min = sphere.center - r,
    max = sphere.center + r,
  }
}

ray_triangle_intersection :: proc(
  ray: Ray,
  tri: Triangle,
  max_t: f32 = F32_MAX,
) -> (hit: bool, t: f32) {
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

ray_sphere_intersection :: proc(
  ray: Ray,
  sphere: Sphere,
  max_t: f32 = F32_MAX,
) -> (hit: bool, t: f32) {
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

PrimitiveType :: enum {
  Triangle,
  Sphere,
}

Primitive :: struct {
  type: PrimitiveType,
  data: union {
    Triangle,
    Sphere,
  },
}

primitive_bounds :: proc(prim: Primitive) -> Aabb {
  switch p in prim.data {
  case Triangle:
    return triangle_bounds(p)
  case Sphere:
    return sphere_bounds(p)
  }
  return AABB_UNDEFINED
}

ray_primitive_intersection :: proc(
  ray: Ray,
  prim: Primitive,
  max_t: f32 = F32_MAX,
) -> (hit: bool, t: f32) {
  switch p in prim.data {
  case Triangle:
    return ray_triangle_intersection(ray, p, max_t)
  case Sphere:
    return ray_sphere_intersection(ray, p, max_t)
  }
  return false, 0
}

sphere_sphere_intersection :: proc(s1: Sphere, s2: Sphere) -> bool {
  d := linalg.length(s1.center - s2.center)
  return d <= (s1.radius + s2.radius)
}

sphere_triangle_intersection :: proc(sphere: Sphere, tri: Triangle) -> bool {
  closest := closest_point_on_triangle(sphere.center, tri)
  d := linalg.length(sphere.center - closest)
  return d <= sphere.radius
}

@(private)
closest_point_on_triangle :: proc(p: [3]f32, tri: Triangle) -> [3]f32 {
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

  vc := d1*d4 - d3*d2
  if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 {
    v := d1 / (d1 - d3)
    return tri.v0 + v * ab
  }

  cp := p - tri.v2
  d5 := linalg.dot(ab, cp)
  d6 := linalg.dot(ac, cp)
  if d6 >= 0.0 && d5 <= d6 do return tri.v2

  vb := d5*d2 - d1*d6
  if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 {
    w := d2 / (d2 - d6)
    return tri.v0 + w * ac
  }

  va := d3*d6 - d5*d4
  if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0 {
    w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
    return tri.v1 + w * (tri.v2 - tri.v1)
  }

  denom := 1.0 / (va + vb + vc)
  v := vb * denom
  w := vc * denom
  return tri.v0 + ab * v + ac * w
}

sphere_primitive_intersection :: proc(sphere: Sphere, prim: Primitive) -> bool {
  switch p in prim.data {
  case Triangle:
    return sphere_triangle_intersection(sphere, p)
  case Sphere:
    return sphere_sphere_intersection(sphere, p)
  }
  return false
}
