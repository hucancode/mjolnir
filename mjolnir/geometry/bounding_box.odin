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

aabb_from_vertices :: proc(vertices: []Vertex) -> (ret: Aabb) {
  if len(vertices) == 0 {
    return
  }
  ret = AABB_UNDEFINED
  for vertex in vertices {
    ret.min = linalg.min(ret.min, vertex.position)
    ret.max = linalg.max(ret.max, vertex.position)
  }
  return ret
}

aabb_union :: proc(a, b: Aabb) -> Aabb {
  return Aabb{
    min = linalg.min(a.min, b.min),
    max = linalg.max(a.max, b.max),
  }
}

aabb_intersects :: proc(a, b: Aabb) -> bool {
  return a.min.x <= b.max.x && a.max.x >= b.min.x &&
         a.min.y <= b.max.y && a.max.y >= b.min.y &&
         a.min.z <= b.max.z && a.max.z >= b.min.z
}

aabb_contains :: proc(outer, inner: Aabb) -> bool {
  return inner.min.x >= outer.min.x && inner.max.x <= outer.max.x &&
         inner.min.y >= outer.min.y && inner.max.y <= outer.max.y &&
         inner.min.z >= outer.min.z && inner.max.z <= outer.max.z
}

aabb_contains_approx :: proc(outer, inner: Aabb, epsilon: f32 = 1e-6) -> bool {
  return inner.min.x >= outer.min.x - epsilon && inner.max.x <= outer.max.x + epsilon &&
         inner.min.y >= outer.min.y - epsilon && inner.max.y <= outer.max.y + epsilon &&
         inner.min.z >= outer.min.z - epsilon && inner.max.z <= outer.max.z + epsilon
}

aabb_contains_point :: proc(aabb: Aabb, point: [3]f32) -> bool {
  return point.x >= aabb.min.x && point.x <= aabb.max.x &&
         point.y >= aabb.min.y && point.y <= aabb.max.y &&
         point.z >= aabb.min.z && point.z <= aabb.max.z
}

aabb_center :: proc(aabb: Aabb) -> [3]f32 {
  return (aabb.min + aabb.max) * 0.5
}

aabb_size :: proc(aabb: Aabb) -> [3]f32 {
  return aabb.max - aabb.min
}

aabb_surface_area :: proc(aabb: Aabb) -> f32 {
  d := aabb.max - aabb.min
  return 2.0 * (d.x * d.y + d.y * d.z + d.z * d.x)
}

aabb_volume :: proc(aabb: Aabb) -> f32 {
  d := aabb.max - aabb.min
  return d.x * d.y * d.z
}

aabb_sphere_intersects :: proc(aabb: Aabb, center: [3]f32, radius: f32) -> bool {
  closest := linalg.clamp(center, aabb.min, aabb.max)
  diff := center - closest
  return linalg.dot(diff, diff) <= radius * radius
}

distance_point_aabb :: proc(point: [3]f32, aabb: Aabb) -> f32 {
  closest := linalg.clamp(point, aabb.min, aabb.max)
  return linalg.length(point - closest)
}

ray_aabb_intersection :: proc(origin: [3]f32, inv_dir: [3]f32, aabb: Aabb) -> (t_near, t_far: f32) {
  t_min := [3]f32{-F32_MAX, -F32_MAX, -F32_MAX}
  t_max := [3]f32{F32_MAX, F32_MAX, F32_MAX}
  for i in 0..<3 {
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

ray_aabb_intersection_far :: proc(origin: [3]f32, inv_dir: [3]f32, aabb: Aabb) -> f32 {
  t1 := (aabb.min - origin) * inv_dir
  t2 := (aabb.max - origin) * inv_dir
  t_max := linalg.max(t1, t2)
  return min(t_max.x, t_max.y, t_max.z)
}

min_vec3 :: proc(v: [3]f32) -> f32 {
  return min(v.x, v.y, v.z)
}

max_vec3 :: proc(v: [3]f32) -> f32 {
  return max(v.x, v.y, v.z)
}

// Oriented Bounding Box
Obb :: struct {
  center:       [3]f32,
  half_extents: [3]f32,
  rotation:     quaternion128, // Orientation
}

// Get the 3 local axes of the OBB (columns of rotation matrix)
obb_axes :: proc(obb: Obb) -> (x, y, z: [3]f32) {
  x = linalg.quaternion128_mul_vector3(obb.rotation, linalg.VECTOR3F32_X_AXIS)
  y = linalg.quaternion128_mul_vector3(obb.rotation, linalg.VECTOR3F32_Y_AXIS)
  z = linalg.quaternion128_mul_vector3(obb.rotation, linalg.VECTOR3F32_Z_AXIS)
  return
}

// Convert OBB to AABB by computing bounds of all 8 corners
obb_to_aabb :: proc(obb: Obb) -> Aabb {
  corners := [8][3]f32 {
    {-obb.half_extents.x, -obb.half_extents.y, -obb.half_extents.z},
    {obb.half_extents.x, -obb.half_extents.y, -obb.half_extents.z},
    {-obb.half_extents.x, obb.half_extents.y, -obb.half_extents.z},
    {obb.half_extents.x, obb.half_extents.y, -obb.half_extents.z},
    {-obb.half_extents.x, -obb.half_extents.y, obb.half_extents.z},
    {obb.half_extents.x, -obb.half_extents.y, obb.half_extents.z},
    {-obb.half_extents.x, obb.half_extents.y, obb.half_extents.z},
    {obb.half_extents.x, obb.half_extents.y, obb.half_extents.z},
  }
  aabb := AABB_UNDEFINED
  for corner in corners {
    rotated := linalg.quaternion128_mul_vector3(obb.rotation, corner)
    world_corner := obb.center + rotated
    aabb.min = linalg.min(aabb.min, world_corner)
    aabb.max = linalg.max(aabb.max, world_corner)
  }
  return aabb
}

// Find closest point on OBB to a given point
obb_closest_point :: proc(obb: Obb, point: [3]f32) -> [3]f32 {
  d := point - obb.center
  // Transform point to OBB local space
  inv_rot := linalg.quaternion_inverse(obb.rotation)
  local := linalg.quaternion128_mul_vector3(inv_rot, d)
  // Clamp to box extents
  clamped := linalg.clamp(local, -obb.half_extents, obb.half_extents)
  // Transform back to world space
  return obb.center + linalg.quaternion128_mul_vector3(obb.rotation, clamped)
}

// Check if point is inside OBB
obb_contains_point :: proc(obb: Obb, point: [3]f32) -> bool {
  d := point - obb.center
  inv_rot := linalg.quaternion_inverse(obb.rotation)
  local := linalg.quaternion128_mul_vector3(inv_rot, d)
  return math.abs(local.x) <= obb.half_extents.x &&
         math.abs(local.y) <= obb.half_extents.y &&
         math.abs(local.z) <= obb.half_extents.z
}

// OBB-OBB intersection test using Separating Axis Theorem
// Returns: hit, contact point, normal (from A to B), penetration depth
obb_obb_intersect :: proc(a: Obb, b: Obb) -> (hit: bool, contact: [3]f32, normal: [3]f32, penetration_depth: f32) {
  // Get rotation matrices for both OBBs
  ax, ay, az := obb_axes(a)
  bx, by, bz := obb_axes(b)

  // Translation vector from A to B
  t := b.center - a.center

  // 15 potential separating axes to test:
  // 3 face normals of A
  // 3 face normals of B
  // 9 cross products of edge pairs (3x3)

  min_overlap := f32(math.F32_MAX)
  best_axis: [3]f32

  // Helper to test a single axis
  test_axis :: proc(axis: [3]f32, t: [3]f32, a: Obb, b: Obb, ax, ay, az, bx, by, bz: [3]f32, min_overlap: ^f32, best_axis: ^[3]f32) -> bool {
    length_sq := linalg.length2(axis)
    if length_sq < 1e-6 do return true // Degenerate axis, skip

    normalized_axis := axis / math.sqrt(length_sq)

    // Project centers onto axis
    dist := linalg.dot(t, normalized_axis)

    // Project extents of A onto axis
    ra := a.half_extents.x * math.abs(linalg.dot(ax, normalized_axis)) +
          a.half_extents.y * math.abs(linalg.dot(ay, normalized_axis)) +
          a.half_extents.z * math.abs(linalg.dot(az, normalized_axis))

    // Project extents of B onto axis
    rb := b.half_extents.x * math.abs(linalg.dot(bx, normalized_axis)) +
          b.half_extents.y * math.abs(linalg.dot(by, normalized_axis)) +
          b.half_extents.z * math.abs(linalg.dot(bz, normalized_axis))

    // Check for separation
    abs_dist := math.abs(dist)
    overlap := ra + rb - abs_dist

    if overlap < 0 do return false // Separating axis found

    // Track minimum overlap
    if overlap < min_overlap^ {
      min_overlap^ = overlap
      // Ensure normal points from A to B
      best_axis^ = dist < 0 ? -normalized_axis : normalized_axis
    }

    return true
  }

  // Test face normals of A
  if !test_axis(ax, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(ay, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(az, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0

  // Test face normals of B
  if !test_axis(bx, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(by, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(bz, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0

  // Test edge-edge axes (9 combinations)
  if !test_axis(linalg.cross(ax, bx), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(ax, by), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(ax, bz), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(ay, bx), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(ay, by), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(ay, bz), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(az, bx), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(az, by), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0
  if !test_axis(linalg.cross(az, bz), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis) do return false, {}, {}, 0

  // All tests passed - OBBs are intersecting
  // Calculate contact point (approximate as midpoint along collision normal)
  contact = a.center + best_axis * (min_overlap * 0.5)

  return true, contact, best_axis, min_overlap
}

// Sphere-OBB intersection test
obb_sphere_intersect :: proc(obb: Obb, sphere_center: [3]f32, sphere_radius: f32) -> (bool, [3]f32, [3]f32, f32) {
  // Find closest point on OBB to sphere center
  closest := obb_closest_point(obb, sphere_center)

  // Vector from closest point to sphere center
  delta := sphere_center - closest
  dist_sq := linalg.length2(delta)

  // Check if sphere intersects
  if dist_sq >= sphere_radius * sphere_radius {
    return false, {}, {}, 0
  }

  distance := math.sqrt(dist_sq)
  normal := distance > 1e-6 ? delta / distance : [3]f32{0, 1, 0}
  penetration := sphere_radius - distance

  return true, closest, normal, penetration
}

// Capsule-OBB intersection test
obb_capsule_intersect :: proc(
  obb: Obb,
  capsule_center: [3]f32,
  capsule_radius: f32,
  capsule_height: f32,
) -> (bool, [3]f32, [3]f32, f32) {
  // Capsule is aligned along Y-axis
  h := capsule_height * 0.5
  line_start := capsule_center + [3]f32{0, -h, 0}
  line_end := capsule_center + [3]f32{0, h, 0}

  // Find closest point on line segment to OBB
  // We'll sample several points along the capsule's central axis
  // and find the one closest to the OBB

  min_dist_sq := f32(math.F32_MAX)
  closest_on_line: [3]f32
  closest_on_obb: [3]f32

  // Sample 5 points along the line segment
  for i in 0..=4 {
    t := f32(i) / 4.0
    sample := linalg.mix(line_start, line_end, t)
    point_on_obb := obb_closest_point(obb, sample)
    dist_sq := linalg.length2(sample - point_on_obb)

    if dist_sq < min_dist_sq {
      min_dist_sq = dist_sq
      closest_on_line = sample
      closest_on_obb = point_on_obb
    }
  }

  // Refine: project the closest OBB point back onto the line segment
  line_dir := line_end - line_start
  line_length_sq := linalg.length2(line_dir)

  if line_length_sq > 1e-6 {
    t := linalg.saturate(linalg.dot(closest_on_obb - line_start, line_dir) / line_length_sq)
    closest_on_line = linalg.mix(line_start, line_end, t)
    closest_on_obb = obb_closest_point(obb, closest_on_line)
  }

  // Check if within capsule radius
  delta := closest_on_line - closest_on_obb
  dist_sq := linalg.length2(delta)

  if dist_sq >= capsule_radius * capsule_radius {
    return false, {}, {}, 0
  }

  distance := math.sqrt(dist_sq)
  normal := distance > 1e-6 ? delta / distance : [3]f32{0, 1, 0}
  penetration := capsule_radius - distance

  return true, closest_on_obb, normal, penetration
}
