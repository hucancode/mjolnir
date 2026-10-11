package geometry

import "core:math"
import "core:math/linalg"

Aabb :: struct {
  min: [3]f32,
  max: [3]f32,
}

AABB_UNDEFINED := Aabb {
  min = {F32_MAX, F32_MAX, F32_MAX},
  max = {F32_MIN, F32_MIN, F32_MIN},
}

aabb_union :: #force_inline proc "contextless" (a, b: Aabb) -> Aabb {
  return Aabb{min = linalg.min(a.min, b.min), max = linalg.max(a.max, b.max)}
}

aabb_intersects :: #force_inline proc "contextless" (a, b: Aabb) -> bool {
  return(
    a.min.x <= b.max.x &&
    a.max.x >= b.min.x &&
    a.min.y <= b.max.y &&
    a.max.y >= b.min.y &&
    a.min.z <= b.max.z &&
    a.max.z >= b.min.z \
  )
}

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

aabb_center :: proc "contextless" (aabb: Aabb) -> [3]f32 {
  return (aabb.min + aabb.max) * 0.5
}

aabb_size :: proc "contextless" (aabb: Aabb) -> [3]f32 {
  return aabb.max - aabb.min
}

aabb_surface_area :: proc "contextless" (aabb: Aabb) -> f32 {
  d := aabb.max - aabb.min
  return 2.0 * (d.x * d.y + d.y * d.z + d.z * d.x)
}

aabb_sphere_intersects :: proc "contextless" (
  aabb: Aabb,
  center: [3]f32,
  radius: f32,
) -> bool {
  closest := linalg.clamp(center, aabb.min, aabb.max)
  diff := center - closest
  return linalg.dot(diff, diff) <= radius * radius
}

ray_aabb_intersection :: proc "contextless" (
  origin: [3]f32,
  inv_dir: [3]f32,
  aabb: Aabb,
) -> (
  t_near, t_far: f32,
) {
  t_min := [3]f32{-F32_MAX, -F32_MAX, -F32_MAX}
  t_max := [3]f32{F32_MAX, F32_MAX, F32_MAX}
  #unroll for i in 0 ..< 3 {
    if math.abs(inv_dir[i]) < 1e-6 {
      // Ray is parallel to this axis
      if origin[i] < aabb.min[i] || origin[i] > aabb.max[i] {
        // Ray is outside the slab, no intersection
        return F32_MAX, -F32_MAX
      }
      // Ray is inside the slab, use the full range
    } else {
      t1 := (aabb.min[i] - origin[i]) * inv_dir[i]
      t2 := (aabb.max[i] - origin[i]) * inv_dir[i]
      t_min[i] = min(t1, t2)
      t_max[i] = max(t1, t2)
    }
  }
  t_near = max(t_min.x, t_min.y, t_min.z)
  t_far = min(t_max.x, t_max.y, t_max.z)
  return
}

ray_aabb_intersection_far :: proc "contextless" (
  origin: [3]f32,
  inv_dir: [3]f32,
  aabb: Aabb,
) -> f32 {
  t1 := (aabb.min - origin) * inv_dir
  t2 := (aabb.max - origin) * inv_dir
  t_max := linalg.max(t1, t2)
  return min(t_max.x, t_max.y, t_max.z)
}

min_vec3 :: proc "contextless" (v: [3]f32) -> f32 {
  return min(v.x, v.y, v.z)
}

// Oriented Bounding Box
Obb :: struct {
  center:       [3]f32,
  half_extents: [3]f32,
  rotation:     quaternion128, // Orientation
}

// Convert OBB to AABB
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

// Find closest point on OBB to a given point
obb_closest_point :: proc "contextless" (obb: Obb, point: [3]f32) -> [3]f32 {
  d := point - obb.center
  // Transform point to OBB local space
  inv_rot := linalg.quaternion_inverse(obb.rotation)
  local := qmv(inv_rot, d)
  // Clamp to box extents
  clamped := linalg.clamp(local, -obb.half_extents, obb.half_extents)
  // Transform back to world space
  return obb.center + qmv(obb.rotation, clamped)
}

// Check if two bounding boxes overlap in 3D
overlap_bounds :: proc "contextless" (amin, amax, bmin, bmax: [3]f32) -> bool {
  return(
    amin.x <= bmax.x &&
    amax.x >= bmin.x &&
    amin.y <= bmax.y &&
    amax.y >= bmin.y &&
    amin.z <= bmax.z &&
    amax.z >= bmin.z \
  )
}

// Check if quantized bounds overlap
overlap_quantized_bounds :: proc "contextless" (
  amin, amax, bmin, bmax: [3]i32,
) -> bool {
  return(
    amin.x <= bmax.x &&
    amax.x >= bmin.x &&
    amin.y <= bmax.y &&
    amax.y >= bmin.y &&
    amin.z <= bmax.z &&
    amax.z >= bmin.z \
  )
}

// Quantize floating point vector to integer coordinates
quantize_float :: proc "contextless" (v: [3]f32, factor: f32) -> [3]i32 {
  scaled := v * factor + 0.5
  return {
    i32(math.floor(scaled.x)),
    i32(math.floor(scaled.y)),
    i32(math.floor(scaled.z)),
  }
}
