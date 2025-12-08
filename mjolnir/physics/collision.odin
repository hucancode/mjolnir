package physics

import "../geometry"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"

is_identity_quaternion :: proc "contextless" (q: quaternion128) -> bool {
  epsilon :: 1e-6
  return(
    math.abs(q.x) < epsilon &&
    math.abs(q.y) < epsilon &&
    math.abs(q.z) < epsilon &&
    math.abs(q.w - 1.0) < epsilon \
  )
}

Contact :: struct {
  body_a:          RigidBodyHandle,
  body_b:          RigidBodyHandle,
  point:           [3]f32,
  normal:          [3]f32,
  penetration:     f32,
  restitution:     f32,
  friction:        f32,
  // Warmstarting: accumulated impulses from this contact
  normal_impulse:  f32,
  tangent_impulse: [2]f32,
  // Cached data for constraint solving
  normal_mass:     f32,
  tangent_mass:    [2]f32,
  bias:            f32, // Position correction bias term
}

// Hash function for collision pairs (for contact caching)
collision_pair_hash :: proc "contextless" (body_a: RigidBodyHandle, body_b: RigidBodyHandle) -> u64 {
  return (u64(body_a.index) << 32) | u64(body_b.index)
}

// Fast bounding sphere intersection test (use before expensive narrow phase)
bounding_spheres_intersect :: proc "contextless" (
  center_a: [3]f32,
  radius_a: f32,
  center_b: [3]f32,
  radius_b: f32,
) -> bool {
  delta := center_b - center_a
  dist_sq := linalg.dot(delta, delta)
  radius_sum := radius_a + radius_b
  return dist_sq <= radius_sum * radius_sum
}

test_sphere_sphere :: proc(
  pos_a: [3]f32,
  sphere_a: SphereCollider,
  pos_b: [3]f32,
  sphere_b: SphereCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  delta := pos_b - pos_a
  distance_sq := linalg.length2(delta)
  radius_sum := sphere_a.radius + sphere_b.radius
  if distance_sq >= radius_sum * radius_sum {
    return
  }
  distance := math.sqrt(distance_sq)
  normal =
    distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = radius_sum - distance
  point = pos_a + normal * (sphere_a.radius - penetration * 0.5)
  hit = true
  return
}

test_box_box :: proc(
  pos_a: [3]f32,
  rot_a: quaternion128,
  box_a: BoxCollider,
  pos_b: [3]f32,
  rot_b: quaternion128,
  box_b: BoxCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  is_a_aligned := is_identity_quaternion(rot_a)
  is_b_aligned := is_identity_quaternion(rot_b)
  // Fast path for axis-aligned boxes
  if is_a_aligned && is_b_aligned {
    min_a := pos_a - box_a.half_extents
    max_a := pos_a + box_a.half_extents
    min_b := pos_b - box_b.half_extents
    max_b := pos_b + box_b.half_extents
    if max_a.x < min_b.x || min_a.x > max_b.x do return
    if max_a.y < min_b.y || min_a.y > max_b.y do return
    if max_a.z < min_b.z || min_a.z > max_b.z do return
    overlap_x := min(max_a.x, max_b.x) - max(min_a.x, min_b.x)
    overlap_y := min(max_a.y, max_b.y) - max(min_a.y, min_b.y)
    overlap_z := min(max_a.z, max_b.z) - max(min_a.z, min_b.z)
    min_overlap := min(overlap_x, overlap_y, overlap_z)
    if min_overlap == overlap_x {
      normal =
        pos_b.x > pos_a.x ? linalg.VECTOR3F32_X_AXIS : -linalg.VECTOR3F32_X_AXIS
      contact_x := pos_b.x > pos_a.x ? max_a.x : min_a.x
      point = [3]f32 {
        contact_x,
        (max(min_a.y, min_b.y) + min(max_a.y, max_b.y)) * 0.5,
        (max(min_a.z, min_b.z) + min(max_a.z, max_b.z)) * 0.5,
      }
    } else if min_overlap == overlap_y {
      normal = pos_b.y > pos_a.y ? linalg.VECTOR3F32_Y_AXIS : -linalg.VECTOR3F32_Y_AXIS
      contact_y := pos_b.y > pos_a.y ? max_a.y : min_a.y
      point = [3]f32 {
        (max(min_a.x, min_b.x) + min(max_a.x, max_b.x)) * 0.5,
        contact_y,
        (max(min_a.z, min_b.z) + min(max_a.z, max_b.z)) * 0.5,
      }
    } else {
      normal =
        pos_b.z > pos_a.z ? linalg.VECTOR3F32_Z_AXIS : -linalg.VECTOR3F32_Z_AXIS
      contact_z := pos_b.z > pos_a.z ? max_a.z : min_a.z
      point = [3]f32 {
        (max(min_a.x, min_b.x) + min(max_a.x, max_b.x)) * 0.5,
        (max(min_a.y, min_b.y) + min(max_a.y, max_b.y)) * 0.5,
        contact_z,
      }
    }
    penetration = min_overlap
    hit = true
    return
  }
  // General case: OBB-OBB collision using SAT
  obb_a := geometry.Obb {
    center       = pos_a,
    half_extents = box_a.half_extents,
    rotation     = rot_a,
  }
  obb_b := geometry.Obb {
    center       = pos_b,
    half_extents = box_b.half_extents,
    rotation     = rot_b,
  }
  return geometry.obb_obb_intersect(obb_a, obb_b)
}

test_box_sphere :: proc(
  pos_box: [3]f32,
  rot_box: quaternion128,
  box: BoxCollider,
  pos_sphere: [3]f32,
  sphere: SphereCollider,
) -> (
  closest: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  is_aligned := is_identity_quaternion(rot_box)
  if is_aligned {
    min_box := pos_box - box.half_extents
    max_box := pos_box + box.half_extents
    closest = linalg.clamp(pos_sphere, min_box, max_box)
    delta := pos_sphere - closest
    distance_sq := linalg.length2(delta)
    if distance_sq >= sphere.radius * sphere.radius {
      return
    }
    distance := math.sqrt(distance_sq)
    normal =
      distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
    penetration = sphere.radius - distance
    hit = true
    return
  }
  obb := geometry.Obb {
    center       = pos_box,
    half_extents = box.half_extents,
    rotation     = rot_box,
  }
  return geometry.obb_sphere_intersect(obb, pos_sphere, sphere.radius)
}

test_capsule_capsule :: proc(
  pos_a: [3]f32,
  rot_a: quaternion128,
  capsule_a: CapsuleCollider,
  pos_b: [3]f32,
  rot_b: quaternion128,
  capsule_b: CapsuleCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  h_a := capsule_a.height * 0.5
  h_b := capsule_b.height * 0.5
  axis_a := linalg.mul(rot_a, linalg.VECTOR3F32_Y_AXIS)
  axis_b := linalg.mul(rot_b, linalg.VECTOR3F32_Y_AXIS)
  line_a_start := pos_a - axis_a * h_a
  line_a_end := pos_a + axis_a * h_a
  line_b_start := pos_b - axis_b * h_b
  line_b_end := pos_b + axis_b * h_b
  point_a, point_b, _, _ := geometry.segment_segment_closest_points(
    line_a_start,
    line_a_end,
    line_b_start,
    line_b_end,
  )
  delta := point_b - point_a
  distance_sq := linalg.length2(delta)
  radius_sum := capsule_a.radius + capsule_b.radius
  if distance_sq >= radius_sum * radius_sum {
    return
  }
  distance := math.sqrt(distance_sq)
  normal =
    distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = radius_sum - distance
  point = point_a + normal * (capsule_a.radius - penetration * 0.5)
  hit = true
  return
}

test_capsule_sphere :: proc(
  pos_capsule: [3]f32,
  rot_capsule: quaternion128,
  capsule: CapsuleCollider,
  pos_sphere: [3]f32,
  sphere: SphereCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  h := capsule.height * 0.5
  axis := linalg.mul(rot_capsule, linalg.VECTOR3F32_Y_AXIS)
  line_start := pos_capsule - axis * h
  line_end := pos_capsule + axis * h
  line_dir := line_end - line_start
  line_length_sq := linalg.length2(line_dir)
  t :=
    line_length_sq < math.F32_EPSILON ? 0 : linalg.saturate(linalg.dot(pos_sphere - line_start, line_dir) / line_length_sq)
  closest := line_start + line_dir * t
  delta := pos_sphere - closest
  distance_sq := linalg.length2(delta)
  radius_sum := sphere.radius + capsule.radius
  if distance_sq >= radius_sum * radius_sum {
    return
  }
  distance := math.sqrt(distance_sq)
  normal =
    distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = radius_sum - distance
  point = closest + normal * (capsule.radius - penetration * 0.5)
  hit = true
  return
}

test_box_capsule :: proc(
  pos_box: [3]f32,
  rot_box: quaternion128,
  box: BoxCollider,
  pos_capsule: [3]f32,
  rot_capsule: quaternion128,
  capsule: CapsuleCollider,
) -> (
  closest: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  is_aligned := is_identity_quaternion(rot_box) && is_identity_quaternion(rot_capsule)
  if is_aligned {
    h := capsule.height * 0.5
    line_start := pos_capsule + [3]f32{0, -h, 0}
    line_end := pos_capsule + [3]f32{0, h, 0}
    min_box := pos_box - box.half_extents
    max_box := pos_box + box.half_extents
    closest_start := linalg.clamp(line_start, min_box, max_box)
    closest_end := linalg.clamp(line_end, min_box, max_box)
    dist_start_sq := linalg.length2(line_start - closest_start)
    dist_end_sq := linalg.length2(line_end - closest_end)
    closest = dist_start_sq < dist_end_sq ? closest_start : closest_end
    point_on_line := dist_start_sq < dist_end_sq ? line_start : line_end
    delta := point_on_line - closest
    distance_sq := linalg.length2(delta)
    if distance_sq >= capsule.radius * capsule.radius {
      return
    }
    distance := math.sqrt(distance_sq)
    normal =
      distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
    penetration = capsule.radius - distance
    hit = true
    return
  }
  // OBB case - transform capsule to box's local space
  // The geometry function assumes Y-aligned capsule, so we rotate the capsule
  h := capsule.height * 0.5
  capsule_axis := linalg.mul(rot_capsule, linalg.VECTOR3F32_Y_AXIS)
  line_start := pos_capsule - capsule_axis * h
  line_end := pos_capsule + capsule_axis * h
  // Transform capsule line segment to box's local space
  inv_rot_box := linalg.quaternion_inverse(rot_box)
  local_start := linalg.mul(inv_rot_box, line_start - pos_box)
  local_end := linalg.mul(inv_rot_box, line_end - pos_box)
  local_center := (local_start + local_end) * 0.5
  local_axis := local_end - local_start
  local_height := linalg.length(local_axis)
  // Find closest points between line segment and box in local space
  clamped_start := linalg.clamp(local_start, -box.half_extents, box.half_extents)
  clamped_end := linalg.clamp(local_end, -box.half_extents, box.half_extents)
  dist_start_sq := linalg.length2(local_start - clamped_start)
  dist_end_sq := linalg.length2(local_end - clamped_end)
  local_closest_on_box := dist_start_sq < dist_end_sq ? clamped_start : clamped_end
  local_point_on_line := dist_start_sq < dist_end_sq ? local_start : local_end
  delta := local_point_on_line - local_closest_on_box
  distance_sq := linalg.length2(delta)
  if distance_sq >= capsule.radius * capsule.radius {
    return
  }
  distance := math.sqrt(distance_sq)
  local_normal :=
    distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  // Transform back to world space
  normal = linalg.mul(rot_box, local_normal)
  closest = pos_box + linalg.mul(rot_box, local_closest_on_box)
  penetration = capsule.radius - distance
  hit = true
  return
}

// Point-in-cylinder test - checks if point is inside a cylinder
test_point_cylinder :: proc(
  point: [3]f32,
  cylinder_center: [3]f32,
  cylinder_rot: quaternion128,
  cylinder: CylinderCollider,
) -> bool {
  // Transform point to cylinder's local space
  local_point := point - cylinder_center
  // Rotate point by inverse of cylinder's rotation
  inv_rot := linalg.quaternion_inverse(cylinder_rot)
  local_point = linalg.mul(inv_rot, local_point)
  // In local space, cylinder axis is Y, check radial distance and height
  half_height := cylinder.height * 0.5
  return(
    linalg.length2(local_point) <= cylinder.radius * cylinder.radius &&
    math.abs(local_point.y) <= half_height \
  )
}

// Point-in-fan test - checks if point is inside a fan (partial cylinder)
test_point_fan :: proc(
  point: [3]f32,
  fan_center: [3]f32,
  fan_rot: quaternion128,
  fan: FanCollider,
) -> bool {
  // Transform point to fan's local space
  local_point := point - fan_center
  // Rotate point by inverse of fan's rotation
  inv_rot := linalg.quaternion_inverse(fan_rot)
  local_point = linalg.mul(inv_rot, local_point)
  // In local space, fan forward direction is +Z, axis is Y
  // Check radial distance and height first (like cylinder)
  radial_dist_sq := linalg.length2(local_point)
  half_height := fan.height * 0.5
  if radial_dist_sq > fan.radius * fan.radius ||
     math.abs(local_point.y) > half_height {
    return false
  }
  // Check if point is within the fan's angular range
  // Forward is +Z, so we measure angle from +Z axis in XZ plane
  if radial_dist_sq < math.F32_EPSILON {
    return true // point is on the axis
  }
  angle_from_forward := math.atan2(local_point.x, local_point.z)
  half_angle := fan.angle * 0.5
  return math.abs(angle_from_forward) <= half_angle
}

test_sphere_cylinder :: proc(
  pos_sphere: [3]f32,
  sphere: SphereCollider,
  pos_cylinder: [3]f32,
  rot_cylinder: quaternion128,
  cylinder: CylinderCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  // Transform sphere to cylinder's local space
  to_sphere := pos_sphere - pos_cylinder
  inv_rot := linalg.quaternion_inverse(rot_cylinder)
  local_sphere := linalg.mul(inv_rot, to_sphere)
  // In local space, cylinder axis is Y
  half_height := cylinder.height * 0.5
  // Clamp sphere center to cylinder height
  clamped_y := linalg.clamp(local_sphere.y, -half_height, half_height)
  // Find closest point on cylinder axis
  axis_point := [3]f32{0, clamped_y, 0}
  // Vector from axis to sphere center in XZ plane
  radial := [3]f32{local_sphere.x, 0, local_sphere.z}
  radial_dist_sq := linalg.length2(radial)
  radial_dist := math.sqrt(radial_dist_sq)
  // Find closest point on cylinder surface
  local_closest: [3]f32
  if radial_dist < math.F32_EPSILON {
    // Sphere is on the cylinder axis
    local_closest = [3]f32{cylinder.radius, clamped_y, 0}
  } else {
    // Project to cylinder surface
    radial_dir := radial / radial_dist
    local_closest = axis_point + radial_dir * cylinder.radius
  }
  // Transform back to world space
  world_closest := pos_cylinder + linalg.mul(rot_cylinder, local_closest)
  delta := pos_sphere - world_closest
  dist_sq := linalg.length2(delta)
  if dist_sq >= sphere.radius * sphere.radius {
    return
  }
  distance := math.sqrt(dist_sq)
  normal =
    distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = sphere.radius - distance
  point = world_closest + normal * (penetration * 0.5)
  hit = true
  return
}

test_box_cylinder :: proc(
  pos_box: [3]f32,
  rot_box: quaternion128,
  box: BoxCollider,
  pos_cylinder: [3]f32,
  rot_cylinder: quaternion128,
  cylinder: CylinderCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  // Transform box to cylinder's local space
  to_box := pos_box - pos_cylinder
  inv_rot := linalg.quaternion_inverse(rot_cylinder)
  local_box_center := linalg.mul(inv_rot, to_box)
  // Transform box rotation to cylinder's local space
  local_box_rot := linalg.mul(inv_rot, rot_box)
  // In cylinder's local space, cylinder is Y-aligned
  half_height := cylinder.height * 0.5
  // Check if box center is within cylinder height range
  if math.abs(local_box_center.y) > half_height + box.half_extents.y {
    return // Box is outside cylinder height range
  }
  // Find closest point on box to cylinder axis
  // For simplicity, check if box AABB (in cylinder space) intersects cylinder
  // Get box axes in cylinder local space
  box_x := linalg.mul(local_box_rot, linalg.VECTOR3F32_X_AXIS)
  box_y := linalg.mul(local_box_rot, linalg.VECTOR3F32_Y_AXIS)
  box_z := linalg.mul(local_box_rot, linalg.VECTOR3F32_Z_AXIS)
  // Find closest point on box surface to cylinder axis (Y-axis)
  // Project box center onto XZ plane
  radial_center := [3]f32{local_box_center.x, 0, local_box_center.z}
  radial_dist := linalg.length(radial_center)
  // Find the point on the box closest to the cylinder axis
  // This is a simplification - we check the box center's radial distance
  // and compare with an expanded radius
  max_box_radius := linalg.length(box.half_extents.xz)
  if radial_dist > cylinder.radius + max_box_radius {
    return // Box is too far from cylinder axis
  }
  // Conservative collision: report collision if AABB check passes
  // This is not perfectly accurate but prevents tunneling
  world_normal := linalg.mul(rot_cylinder, [3]f32{1, 0, 0})
  world_point := pos_box
  normal = world_normal
  point = world_point
  penetration = 0.1 // Conservative small penetration
  hit = true
  return
}

test_capsule_cylinder :: proc(
  pos_capsule: [3]f32,
  rot_capsule: quaternion128,
  capsule: CapsuleCollider,
  pos_cylinder: [3]f32,
  rot_cylinder: quaternion128,
  cylinder: CylinderCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  // Transform capsule to cylinder's local space
  to_capsule := pos_capsule - pos_cylinder
  inv_rot := linalg.quaternion_inverse(rot_cylinder)
  local_capsule_center := linalg.mul(inv_rot, to_capsule)
  // In local space, cylinder is Y-aligned
  // Capsule also has a rotation now
  local_capsule_rot := linalg.mul(inv_rot, rot_capsule)
  half_height_capsule := capsule.height * 0.5
  half_height_cylinder := cylinder.height * 0.5
  // Capsule line segment in cylinder local space
  capsule_axis := linalg.mul(local_capsule_rot, linalg.VECTOR3F32_Y_AXIS)
  line_start := local_capsule_center - capsule_axis * half_height_capsule
  line_end := local_capsule_center + capsule_axis * half_height_capsule
  // Simplified check if both are Y-aligned (common case)
  // is_capsule_y_aligned := math.abs(capsule_axis.y) > 0.99
  // if !is_capsule_y_aligned {
  //   return
  // }
  // Since both shapes are Y-aligned in cylinder's local space, check radial distance
  // Find radial distance in XZ plane at capsule center height
  radial := [3]f32{local_capsule_center.x, 0, local_capsule_center.z}
  radial_dist := linalg.length(radial)
  radius_sum := capsule.radius + cylinder.radius
  // Check if capsule is within radial distance
  if radial_dist >= radius_sum {
    return
  }
  // Check height overlap
  min_capsule := local_capsule_center.y - half_height_capsule
  max_capsule := local_capsule_center.y + half_height_capsule
  min_cylinder := -half_height_cylinder
  max_cylinder := half_height_cylinder
  if max_capsule < min_cylinder || min_capsule > max_cylinder {
    return
  }
  // Calculate collision
  radial_dir :=
    radial_dist > math.F32_EPSILON ? radial / radial_dist : [3]f32{1, 0, 0}
  local_normal := radial_dir
  local_point :=
    local_capsule_center +
    local_normal * (capsule.radius - (radius_sum - radial_dist) * 0.5)
  // Transform back to world space
  world_normal := linalg.mul(rot_cylinder, local_normal)
  world_point := pos_cylinder + linalg.mul(rot_cylinder, local_point)
  normal = world_normal
  point = world_point
  penetration = radius_sum - radial_dist
  hit = true
  return
}

test_cylinder_cylinder :: proc(
  pos_a: [3]f32,
  rot_a: quaternion128,
  cylinder_a: CylinderCollider,
  pos_b: [3]f32,
  rot_b: quaternion128,
  cylinder_b: CylinderCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  // Transform cylinder B to cylinder A's local space
  to_b := pos_b - pos_a
  inv_rot_a := linalg.quaternion_inverse(rot_a)
  local_b_center := linalg.mul(inv_rot_a, to_b)
  // Cylinder B's axis in cylinder A's local space
  b_axis_world := linalg.mul(rot_b, linalg.VECTOR3F32_Y_AXIS)
  b_axis_local := linalg.mul(inv_rot_a, b_axis_world)
  // Check if axes are parallel
  parallel := math.abs(math.abs(b_axis_local.y) - 1.0) < 0.01
  if parallel {
    // Axes are parallel - treat as 2D circle-circle in XZ plane
    radial := [3]f32{local_b_center.x, 0, local_b_center.z}
    radial_dist := linalg.length(radial)
    radius_sum := cylinder_a.radius + cylinder_b.radius
    if radial_dist >= radius_sum {
      return
    }
    // Check height overlap
    half_height_a := cylinder_a.height * 0.5
    half_height_b := cylinder_b.height * 0.5
    min_a := -half_height_a
    max_a := half_height_a
    min_b := local_b_center.y - half_height_b
    max_b := local_b_center.y + half_height_b
    if max_a < min_b || min_a > max_b {
      return
    }
    // Collision detected
    radial_dir :=
      radial_dist > math.F32_EPSILON ? radial / radial_dist : [3]f32{1, 0, 0}
    local_normal := radial_dir
    local_point :=
      local_normal * (cylinder_a.radius - (radius_sum - radial_dist) * 0.5)
    // Transform back to world space
    world_normal := linalg.mul(rot_a, local_normal)
    world_point := pos_a + linalg.mul(rot_a, local_point)
    normal = world_normal
    point = world_point
    penetration = radius_sum - radial_dist
    hit = true
    return
  }
  // Non-parallel cylinders - use sphere approximation at cylinder centers
  // This is conservative but prevents tunneling
  sphere_a_radius := linalg.length(
    [2]f32{cylinder_a.radius, cylinder_a.height * 0.5},
  )
  sphere_b_radius := linalg.length(
    [2]f32{cylinder_b.radius, cylinder_b.height * 0.5},
  )
  delta := pos_b - pos_a
  dist_sq := linalg.length2(delta)
  radius_sum := sphere_a_radius + sphere_b_radius
  if dist_sq >= radius_sum * radius_sum {
    return
  }
  distance := math.sqrt(dist_sq)
  normal =
    distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
  penetration = radius_sum - distance
  point = pos_a + normal * (sphere_a_radius - penetration * 0.5)
  hit = true
  return
}

test_collision :: proc(
  collider_a: ^Collider,
  pos_a: [3]f32,
  rot_a: quaternion128,
  collider_b: ^Collider,
  pos_b: [3]f32,
  rot_b: quaternion128,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  center_a := pos_a + linalg.mul(rot_a, collider_a.offset)
  center_b := pos_b + linalg.mul(rot_b, collider_b.offset)
  // Cylinder can be solid and uses GJK fallback
  switch shape_a in collider_a.shape {
  case FanCollider:
    return
  case SphereCollider:
    switch shape_b in collider_b.shape {
    case FanCollider:
      return
    case SphereCollider:
      return test_sphere_sphere(center_a, shape_a, center_b, shape_b)
    case BoxCollider:
      point, normal, penetration, hit = test_box_sphere(
        center_b,
        rot_b,
        shape_b,
        center_a,
        shape_a,
      )
      normal = -normal
      return
    case CapsuleCollider:
      point, normal, penetration, hit = test_capsule_sphere(
        center_b,
        rot_b,
        shape_b,
        center_a,
        shape_a,
      )
      normal = -normal
      return
    case CylinderCollider:
      return test_sphere_cylinder(center_a, shape_a, center_b, rot_b, shape_b)
    }
  case BoxCollider:
    switch shape_b in collider_b.shape {
    case FanCollider:
      return
    case SphereCollider:
      return test_box_sphere(center_a, rot_a, shape_a, center_b, shape_b)
    case BoxCollider:
      return test_box_box(center_a, rot_a, shape_a, center_b, rot_b, shape_b)
    case CapsuleCollider:
      return test_box_capsule(
        center_a,
        rot_a,
        shape_a,
        center_b,
        rot_b,
        shape_b,
      )
    case CylinderCollider:
      return test_box_cylinder(
        center_a,
        rot_a,
        shape_a,
        center_b,
        rot_b,
        shape_b,
      )
    }
  case CapsuleCollider:
    switch shape_b in collider_b.shape {
    case FanCollider:
      return
    case SphereCollider:
      return test_capsule_sphere(center_a, rot_a, shape_a, center_b, shape_b)
    case BoxCollider:
      point, normal, penetration, hit = test_box_capsule(
        center_b,
        rot_b,
        shape_b,
        center_a,
        rot_a,
        shape_a,
      )
      normal = -normal
      return
    case CapsuleCollider:
      return test_capsule_capsule(
        center_a,
        rot_a,
        shape_a,
        center_b,
        rot_b,
        shape_b,
      )
    case CylinderCollider:
      return test_capsule_cylinder(
        center_a,
        rot_a,
        shape_a,
        center_b,
        rot_b,
        shape_b,
      )
    }
  case CylinderCollider:
    switch shape_b in collider_b.shape {
    case FanCollider:
      return
    case SphereCollider:
      point, normal, penetration, hit = test_sphere_cylinder(
        center_b,
        shape_b,
        center_a,
        rot_a,
        shape_a,
      )
      normal = -normal
      return
    case BoxCollider:
      point, normal, penetration, hit = test_box_cylinder(
        center_b,
        rot_b,
        shape_b,
        center_a,
        rot_a,
        shape_a,
      )
      normal = -normal
      return
    case CapsuleCollider:
      point, normal, penetration, hit = test_capsule_cylinder(
        center_b,
        rot_b,
        shape_b,
        center_a,
        rot_a,
        shape_a,
      )
      normal = -normal
      return
    case CylinderCollider:
      return test_cylinder_cylinder(
        center_a,
        rot_a,
        shape_a,
        center_b,
        rot_b,
        shape_b,
      )
    }
  }
  return
}

test_collision_gjk :: proc(
  collider_a: ^Collider,
  pos_a: [3]f32,
  rot_a: quaternion128,
  collider_b: ^Collider,
  pos_b: [3]f32,
  rot_b: quaternion128,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  simplex: Simplex
  if !gjk(collider_a, pos_a, rot_a, collider_b, pos_b, rot_b, &simplex) {
    return
  }
  normal, penetration, hit = epa(
    simplex,
    collider_a,
    pos_a,
    rot_a,
    collider_b,
    pos_b,
    rot_b,
  )
  if !hit {
    return
  }
  center_a := pos_a + linalg.mul(rot_a, collider_a.offset)
  center_b := pos_b + linalg.mul(rot_b, collider_b.offset)
  point = center_a + normal * penetration * 0.5
  return
}
