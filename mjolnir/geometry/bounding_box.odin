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

aabb_union :: proc "contextless" (a, b: Aabb) -> Aabb {
  return Aabb{min = linalg.min(a.min, b.min), max = linalg.max(a.max, b.max)}
}

aabb_intersects :: proc "contextless" (a, b: Aabb) -> bool {
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

aabb_contains_approx :: proc "contextless" (
  outer, inner: Aabb,
  epsilon: f32 = 1e-6,
) -> bool {
  return(
    inner.min.x >= outer.min.x - epsilon &&
    inner.max.x <= outer.max.x + epsilon &&
    inner.min.y >= outer.min.y - epsilon &&
    inner.max.y <= outer.max.y + epsilon &&
    inner.min.z >= outer.min.z - epsilon &&
    inner.max.z <= outer.max.z + epsilon \
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

aabb_volume :: proc "contextless" (aabb: Aabb) -> f32 {
  d := aabb.max - aabb.min
  return d.x * d.y * d.z
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

distance_point_aabb :: proc "contextless" (point: [3]f32, aabb: Aabb) -> f32 {
  closest := linalg.clamp(point, aabb.min, aabb.max)
  return linalg.length(point - closest)
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

max_vec3 :: proc "contextless" (v: [3]f32) -> f32 {
  return max(v.x, v.y, v.z)
}

// Oriented Bounding Box
Obb :: struct {
  center:       [3]f32,
  half_extents: [3]f32,
  rotation:     quaternion128, // Orientation
}

// Get the 3 local axes of the OBB (columns of rotation matrix)
obb_axes :: proc "contextless" (obb: Obb) -> (x, y, z: [3]f32) {
  x = linalg.mul(obb.rotation, linalg.VECTOR3F32_X_AXIS)
  y = linalg.mul(obb.rotation, linalg.VECTOR3F32_Y_AXIS)
  z = linalg.mul(obb.rotation, linalg.VECTOR3F32_Z_AXIS)
  return
}

// Convert OBB to AABB by computing bounds of all 8 corners
obb_to_aabb :: proc "contextless" (obb: Obb) -> Aabb {
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
    rotated := linalg.mul(obb.rotation, corner)
    world_corner := obb.center + rotated
    aabb.min = linalg.min(aabb.min, world_corner)
    aabb.max = linalg.max(aabb.max, world_corner)
  }
  return aabb
}

// Find closest point on OBB to a given point
obb_closest_point :: proc "contextless" (obb: Obb, point: [3]f32) -> [3]f32 {
  d := point - obb.center
  // Transform point to OBB local space
  inv_rot := linalg.quaternion_inverse(obb.rotation)
  local := linalg.mul(inv_rot, d)
  // Clamp to box extents
  clamped := linalg.clamp(local, -obb.half_extents, obb.half_extents)
  // Transform back to world space
  return obb.center + linalg.mul(obb.rotation, clamped)
}

// Check if point is inside OBB
obb_contains_point :: proc "contextless" (obb: Obb, point: [3]f32) -> bool {
  d := point - obb.center
  inv_rot := linalg.quaternion_inverse(obb.rotation)
  local := linalg.mul(inv_rot, d)
  return(
    math.abs(local.x) <= obb.half_extents.x &&
    math.abs(local.y) <= obb.half_extents.y &&
    math.abs(local.z) <= obb.half_extents.z \
  )
}

// OBB-OBB intersection test using Separating Axis Theorem
obb_obb_intersect :: proc(
  a: Obb,
  b: Obb,
) -> (
  contact: [3]f32,
  normal: [3]f32,
  penetration_depth: f32,
  hit: bool,
) {
  mat_a := linalg.matrix3_from_quaternion(a.rotation)
  mat_b := linalg.matrix3_from_quaternion(b.rotation)
  ax, ay, az := mat_a[0], mat_a[1], mat_a[2]
  bx, by, bz := mat_b[0], mat_b[1], mat_b[2]
  t := b.center - a.center
  min_overlap := f32(math.F32_MAX)
  best_axis: [3]f32
  best_axis_index := -1 // 0-2: A faces, 3-5: B faces, 6+: edges
  // Helper to test a single axis
  test_axis :: #force_inline proc(
    axis: [3]f32,
    t: [3]f32,
    a: Obb,
    b: Obb,
    ax, ay, az, bx, by, bz: [3]f32,
    min_overlap: ^f32,
    best_axis: ^[3]f32,
    best_index: ^int,
    current_index: int,
  ) -> bool {
    // Skip degenerate axes (e.g., parallel edges produce near-zero cross products)
    axis_sq := linalg.length2(axis)
    if axis_sq < 1e-8 do return true
    // Project centers onto axis
    dist := linalg.dot(t, axis)
    // Project extents of A onto axis
    ra :=
      a.half_extents.x * math.abs(linalg.dot(ax, axis)) +
      a.half_extents.y * math.abs(linalg.dot(ay, axis)) +
      a.half_extents.z * math.abs(linalg.dot(az, axis))
    // Project extents of B onto axis
    rb :=
      b.half_extents.x * math.abs(linalg.dot(bx, axis)) +
      b.half_extents.y * math.abs(linalg.dot(by, axis)) +
      b.half_extents.z * math.abs(linalg.dot(bz, axis))
    // Check for separation
    overlap := ra + rb - math.abs(dist)
    if overlap < 0 do return false // Separating axis found
    // Track minimum overlap
    if overlap < min_overlap^ {
      min_overlap^ = overlap
      // Ensure normal points from A to B
      best_axis^ = dist < 0 ? -axis : axis
      best_index^ = current_index
    }
    return true
  }
  // Test face normals of A (indices 0-2)
  test_axis(ax, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 0) or_return
  test_axis(ay, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 1) or_return
  test_axis(az, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 2) or_return
  // Test face normals of B (indices 3-5)
  test_axis(bx, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 3) or_return
  test_axis(by, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 4) or_return
  test_axis(bz, t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 5) or_return
  // Test edge-edge axes (indices 6+)
  test_axis(linalg.cross(ax, bx), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 6) or_return
  test_axis(linalg.cross(ax, by), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 7) or_return
  test_axis(linalg.cross(ax, bz), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 8) or_return
  test_axis(linalg.cross(ay, bx), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 9) or_return
  test_axis(linalg.cross(ay, by), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 10) or_return
  test_axis(linalg.cross(ay, bz), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 11) or_return
  test_axis(linalg.cross(az, bx), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 12) or_return
  test_axis(linalg.cross(az, by), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 13) or_return
  test_axis(linalg.cross(az, bz), t, a, b, ax, ay, az, bx, by, bz, &min_overlap, &best_axis, &best_axis_index, 14) or_return
  // All tests passed - OBBs are intersecting
  // Normalize the best axis (face normals are already unit length, but edge axes may not be)
  normal = linalg.normalize0(best_axis)
  penetration_depth = min_overlap
  // For face-face collisions (best axis is a face normal), compute better contact point
  if best_axis_index >= 0 && best_axis_index <= 5 {
    // Face-face collision: find the center of the contact region on the reference face
    reference_is_a := best_axis_index <= 2
    reference_obb := reference_is_a ? a : b
    incident_obb := reference_is_a ? b : a
    axis_index := reference_is_a ? best_axis_index : best_axis_index - 3
    // best_axis points from A to B; when using B as reference we need the face that looks back at A
    reference_normal := reference_is_a ? best_axis : -best_axis
    reference_face_center :=
      reference_obb.center + reference_normal * reference_obb.half_extents[axis_index]
    // Get all 8 vertices of incident box using cached axes
    inc_x, inc_y, inc_z := (reference_is_a ? bx : ax), (reference_is_a ? by : ay), (reference_is_a ? bz : az)
    inc_ex, inc_ey, inc_ez := incident_obb.half_extents.x, incident_obb.half_extents.y, incident_obb.half_extents.z
    incident_vertices := [8][3]f32{
      incident_obb.center - inc_x * inc_ex - inc_y * inc_ey - inc_z * inc_ez,
      incident_obb.center + inc_x * inc_ex - inc_y * inc_ey - inc_z * inc_ez,
      incident_obb.center - inc_x * inc_ex + inc_y * inc_ey - inc_z * inc_ez,
      incident_obb.center + inc_x * inc_ex + inc_y * inc_ey - inc_z * inc_ez,
      incident_obb.center - inc_x * inc_ex - inc_y * inc_ey + inc_z * inc_ez,
      incident_obb.center + inc_x * inc_ex - inc_y * inc_ey + inc_z * inc_ez,
      incident_obb.center - inc_x * inc_ex + inc_y * inc_ey + inc_z * inc_ez,
      incident_obb.center + inc_x * inc_ex + inc_y * inc_ey + inc_z * inc_ez,
    }
    // Find vertices that are penetrating the reference face
    contact_sum := [3]f32{0, 0, 0}
    contact_count := 0
    for vertex in incident_vertices {
      // Signed distance from vertex to reference face plane (reference_normal points out of reference)
      dist_to_face := linalg.dot(vertex - reference_face_center, reference_normal)
      // If the vertex is behind or on the reference face, project it onto the face plane
      if dist_to_face <= 1e-4 {
        projected := vertex - reference_normal * dist_to_face
        contact_sum += projected
        contact_count += 1
      }
    }
    // Average the penetrating vertices
    if contact_count > 0 {
      contact = contact_sum / f32(contact_count)
    } else {
      // Fallback: midpoint between the reference face and incident object along the collision normal
      contact =
        reference_face_center - reference_normal * min_overlap * 0.5
    }
  } else {
    // Edge-edge collision: use midpoint approximation
    contact = a.center + best_axis * min_overlap * 0.5
  }
  hit = true
  return
}

// Sphere-OBB intersection test
obb_sphere_intersect :: proc(
  obb: Obb,
  sphere_center: [3]f32,
  sphere_radius: f32,
) -> (
  closest: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  // Find closest point on OBB to sphere center
  closest = obb_closest_point(obb, sphere_center)
  // Vector from closest point to sphere center
  delta := sphere_center - closest
  dist_sq := linalg.length2(delta)
  // Check if sphere intersects
  if dist_sq >= sphere_radius * sphere_radius {
    return
  }
  distance := math.sqrt(dist_sq)
  normal = distance > 1e-6 ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = sphere_radius - distance
  hit = true
  return
}

// Capsule-OBB intersection test
obb_capsule_intersect :: proc(
  obb: Obb,
  capsule_center: [3]f32,
  capsule_radius: f32,
  capsule_height: f32,
) -> (
  closest_on_obb: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  // Capsule is aligned along Y-axis
  h := capsule_height * 0.5
  line_start := capsule_center + [3]f32{0, -h, 0}
  line_end := capsule_center + [3]f32{0, h, 0}
  // Find closest point on line segment to OBB
  // We'll sample several points along the capsule's central axis
  // and find the one closest to the OBB
  min_dist_sq := f32(math.F32_MAX)
  closest_on_line: [3]f32
  // Sample 5 points along the line segment
  #unroll for i in 0 ..= 4 {
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
    t := linalg.saturate(
      linalg.dot(closest_on_obb - line_start, line_dir) / line_length_sq,
    )
    closest_on_line = linalg.mix(line_start, line_end, t)
    closest_on_obb = obb_closest_point(obb, closest_on_line)
  }
  // Check if within capsule radius
  delta := closest_on_line - closest_on_obb
  dist_sq := linalg.length2(delta)
  if dist_sq >= capsule_radius * capsule_radius {
    return
  }
  distance := math.sqrt(dist_sq)
  normal = distance > 1e-6 ? delta / distance : [3]f32{0, 1, 0}
  penetration = capsule_radius - distance
  hit = true
  return
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
