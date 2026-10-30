package geometry

import "core:math"
import "core:math/linalg"

// Aabb is an axis-aligned bounding box given by its min and max corners.
Aabb :: struct {
  min: [3]f32,
  max: [3]f32,
}

// AABB_UNDEFINED is an inverted (empty) box, the identity for aabb_union.
AABB_UNDEFINED := Aabb {
  min = {F32_MAX, F32_MAX, F32_MAX},
  max = {F32_MIN, F32_MIN, F32_MIN},
}

// aabb_union returns the smallest box containing both a and b.
aabb_union :: #force_inline proc "contextless" (a, b: Aabb) -> Aabb {
  return Aabb{min = linalg.min(a.min, b.min), max = linalg.max(a.max, b.max)}
}

// aabb_intersects reports whether a and b overlap (touching counts).
aabb_intersects :: #force_inline proc "contextless" (a, b: Aabb) -> bool {
  return overlap_bounds(a.min, a.max, b.min, b.max)
}

// aabb_contains reports whether inner lies fully inside outer.
aabb_contains :: proc "contextless" (outer, inner: Aabb) -> bool {
  return(
    inner.min.x >= outer.min.x &&
    inner.max.x <= outer.max.x &&
    inner.min.y >= outer.min.y &&
    inner.max.y <= outer.max.y &&
    inner.min.z >= outer.min.z &&
    inner.max.z <= outer.max.z \
  )
}

// aabb_contains_point reports whether point lies inside aabb, boundary included.
aabb_contains_point :: proc "contextless" (aabb: Aabb, point: [3]f32) -> bool {
  return(
    point.x >= aabb.min.x &&
    point.x <= aabb.max.x &&
    point.y >= aabb.min.y &&
    point.y <= aabb.max.y &&
    point.z >= aabb.min.z &&
    point.z <= aabb.max.z \
  )
}

// aabb_center returns the center of aabb.
aabb_center :: proc "contextless" (aabb: Aabb) -> [3]f32 {
  return (aabb.min + aabb.max) * 0.5
}

// aabb_size returns the extent of aabb along each axis.
aabb_size :: proc "contextless" (aabb: Aabb) -> [3]f32 {
  return aabb.max - aabb.min
}

// aabb_surface_area returns the total area of aabb's six faces.
aabb_surface_area :: proc "contextless" (aabb: Aabb) -> f32 {
  d := aabb.max - aabb.min
  return 2.0 * (d.x * d.y + d.y * d.z + d.z * d.x)
}

// aabb_sphere_intersects reports whether the sphere overlaps aabb.
aabb_sphere_intersects :: proc "contextless" (
  aabb: Aabb,
  center: [3]f32,
  radius: f32,
) -> bool {
  closest := linalg.clamp(center, aabb.min, aabb.max)
  diff := center - closest
  return linalg.dot(diff, diff) <= radius * radius
}

// ray_aabb_intersection returns the entry and exit distances of a ray (origin, 1/direction)
// through aabb; t_far < t_near means a miss. An axis-parallel ray has an infinite inverse there.
ray_aabb_intersection :: #force_inline proc "contextless" (
  origin: [3]f32,
  inv_dir: [3]f32,
  aabb: Aabb,
) -> (
  t_near, t_far: f32,
) {
  t1 := (aabb.min - origin) * inv_dir
  t2 := (aabb.max - origin) * inv_dir
  lo, hi := linalg.min(t1, t2), linalg.max(t1, t2)
  return max(lo.x, lo.y, lo.z), min(hi.x, hi.y, hi.z)
}

// Obb is an oriented bounding box.
Obb :: struct {
  center:       [3]f32,
  half_extents: [3]f32,
  rotation:     quaternion128, // Orientation
}

// obb_to_aabb returns the axis-aligned box enclosing obb.
obb_to_aabb :: #force_inline proc "contextless" (obb: Obb) -> Aabb {
  r := linalg.matrix3_from_quaternion(obb.rotation)
  h := obb.half_extents
  e := [3]f32{
    linalg.dot(linalg.abs(r[0]), h),
    linalg.dot(linalg.abs(r[1]), h),
    linalg.dot(linalg.abs(r[2]), h),
  }
  return Aabb{min = obb.center - e, max = obb.center + e}
}

// obb_closest_point returns the point on obb nearest to point.
obb_closest_point :: proc "contextless" (obb: Obb, point: [3]f32) -> [3]f32 {
  d := point - obb.center
  inv_rot := linalg.quaternion_inverse(obb.rotation)
  local := linalg.mul(inv_rot, d)
  clamped := linalg.clamp(local, -obb.half_extents, obb.half_extents)
  return obb.center + linalg.mul(obb.rotation, clamped)
}

// overlap_bounds reports whether boxes (amin, amax) and (bmin, bmax) overlap, touching counts;
// float or quantized (integer) corners.
overlap_bounds :: #force_inline proc "contextless" (amin, amax, bmin, bmax: [3]$T) -> bool {
  return(
    amin.x <= bmax.x &&
    amax.x >= bmin.x &&
    amin.y <= bmax.y &&
    amax.y >= bmin.y &&
    amin.z <= bmax.z &&
    amax.z >= bmin.z   )
}

// quantize_float scales v by factor and rounds to integer coordinates.
quantize_float :: proc "contextless" (v: [3]f32, factor: f32) -> [3]i32 {
  scaled := v * factor + 0.5
  return {
    i32(math.floor(scaled.x)),
    i32(math.floor(scaled.y)),
    i32(math.floor(scaled.z)),
  }
}
