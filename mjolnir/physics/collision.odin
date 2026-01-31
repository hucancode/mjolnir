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

// Contact between two dynamic bodies
DynamicContact :: struct {
  body_a:          DynamicRigidBodyHandle,
  body_b:          DynamicRigidBodyHandle,
  point:           [3]f32,
  normal:          [3]f32,
  penetration:     f32,
  restitution:     f32,
  friction:        f32,
  normal_impulse:  f32,
  tangent_impulse: [2]f32,
  normal_mass:     f32,
  tangent_mass:    [2]f32,
  bias:            f32,
  r_a:             [3]f32,
  r_b:             [3]f32,
  tangent1:        [3]f32,
  tangent2:        [3]f32,
}

// Contact between dynamic body (A) and static body (B)
StaticContact :: struct {
  body_a:          DynamicRigidBodyHandle,
  body_b:          StaticRigidBodyHandle,
  point:           [3]f32,
  normal:          [3]f32,
  penetration:     f32,
  restitution:     f32,
  friction:        f32,
  normal_impulse:  f32,
  tangent_impulse: [2]f32,
  normal_mass:     f32,
  tangent_mass:    [2]f32,
  bias:            f32,
  r_a:             [3]f32,
  tangent1:        [3]f32,
  tangent2:        [3]f32,
}

collision_pair_hash_dynamic :: proc "contextless" (
  body_a: DynamicRigidBodyHandle,
  body_b: DynamicRigidBodyHandle,
) -> u64 {
  return (u64(body_a.index) << 32) | u64(body_b.index)
}

collision_pair_hash_static :: proc "contextless" (
  body_a: DynamicRigidBodyHandle,
  body_b: StaticRigidBodyHandle,
) -> u64 {
  a_index := body_a.index
  b_index := body_b.index | 0x80000000
  return (u64(a_index) << 32) | u64(b_index)
}

collision_pair_hash :: proc {
  collision_pair_hash_dynamic,
  collision_pair_hash_static,
}

// Fast bounding sphere intersection test (use before expensive narrow phase)
bounding_spheres_intersect :: proc "contextless" (
  pos_a: [3]f32,
  radius_a: f32,
  pos_b: [3]f32,
  radius_b: f32,
) -> bool {
  delta := pos_b - pos_a
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
  if distance_sq > radius_sum * radius_sum {
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
      normal =
        pos_b.y > pos_a.y ? linalg.VECTOR3F32_Y_AXIS : -linalg.VECTOR3F32_Y_AXIS
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
  return geometry.obb_obb_intersect(
    {center = pos_a, half_extents = box_a.half_extents, rotation = rot_a},
    {center = pos_b, half_extents = box_b.half_extents, rotation = rot_b},
  )
}

test_box_sphere :: proc(
  pos_box: [3]f32,
  rot_box: quaternion128,
  box: BoxCollider,
  pos_sphere: [3]f32,
  sphere: SphereCollider,
  invert_normal: bool = false,
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
    if distance_sq > sphere.radius * sphere.radius {
      return
    }
    distance := math.sqrt(distance_sq)
    normal =
      distance > math.F32_EPSILON ? delta / distance : linalg.VECTOR3F32_Y_AXIS
    if invert_normal do normal = -normal
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
  local_point = geometry.qmv(inv_rot, local_point)
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
  local_point = geometry.qmv(inv_rot, local_point)
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
  invert_normal: bool = false,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  // Transform sphere to cylinder's local space
  to_sphere := pos_sphere - pos_cylinder
  inv_rot := linalg.quaternion_inverse(rot_cylinder)
  local_sphere := geometry.qmv(inv_rot, to_sphere)
  // In local space, cylinder axis is Y
  half_height := cylinder.height * 0.5
  // Vector from axis to sphere center in XZ plane
  radial := [3]f32{local_sphere.x, 0, local_sphere.z}
  radial_dist := linalg.length(radial)
  // Determine which region the sphere center is in
  above_cylinder := local_sphere.y > half_height
  below_cylinder := local_sphere.y < -half_height
  inside_height := !above_cylinder && !below_cylinder
  inside_radial := radial_dist < cylinder.radius
  // Find closest point on cylinder surface
  local_closest: [3]f32
  if above_cylinder || below_cylinder {
    // Sphere center is above or below the cylinder
    cap_y := above_cylinder ? half_height : -half_height
    if inside_radial {
      // Closest point is on the cap (directly above/below sphere)
      local_closest = [3]f32{local_sphere.x, cap_y, local_sphere.z}
    } else {
      // Closest point is on the rim (edge of cap)
      radial_dir := radial / radial_dist
      local_closest = [3]f32 {
        radial_dir.x * cylinder.radius,
        cap_y,
        radial_dir.z * cylinder.radius,
      }
    }
  } else if inside_radial {
    // Sphere center is INSIDE the cylinder - find minimum penetration axis
    dist_to_top := half_height - local_sphere.y
    dist_to_bottom := local_sphere.y + half_height
    dist_to_side := cylinder.radius - radial_dist
    if dist_to_side <= dist_to_top && dist_to_side <= dist_to_bottom {
      // Push out through curved surface
      if radial_dist < math.F32_EPSILON {
        local_closest = [3]f32{cylinder.radius, local_sphere.y, 0}
      } else {
        radial_dir := radial / radial_dist
        local_closest = [3]f32 {
          radial_dir.x * cylinder.radius,
          local_sphere.y,
          radial_dir.z * cylinder.radius,
        }
      }
    } else if dist_to_top <= dist_to_bottom {
      // Push out through top cap
      local_closest = [3]f32{local_sphere.x, half_height, local_sphere.z}
    } else {
      // Push out through bottom cap
      local_closest = [3]f32{local_sphere.x, -half_height, local_sphere.z}
    }
  } else {
    // Sphere center is outside radial extent - closest on curved surface
    radial_dir := radial / radial_dist
    clamped_y := linalg.clamp(local_sphere.y, -half_height, half_height)
    local_closest = [3]f32 {
      radial_dir.x * cylinder.radius,
      clamped_y,
      radial_dir.z * cylinder.radius,
    }
  }
  // Compute surface normal based on which surface the closest point is on
  local_normal: [3]f32
  if local_closest.y >= half_height - math.F32_EPSILON {
    // On top cap
    local_normal = {0, 1, 0}
  } else if local_closest.y <= -half_height + math.F32_EPSILON {
    // On bottom cap
    local_normal = {0, -1, 0}
  } else {
    // On curved surface
    local_normal = linalg.normalize(
      [3]f32{local_closest.x, 0, local_closest.z},
    )
  }
  // Transform to world space
  world_closest := pos_cylinder + geometry.qmv(rot_cylinder, local_closest)
  world_normal := geometry.qmv(rot_cylinder, local_normal)
  delta := pos_sphere - world_closest
  dist_sq := linalg.length2(delta)
  if dist_sq > sphere.radius * sphere.radius {
    return
  }
  distance := math.sqrt(dist_sq)
  // Use surface normal (more stable than delta-based normal when deeply penetrating)
  normal = world_normal
  penetration = sphere.radius - distance
  // Contact point is between the surfaces
  point = world_closest + normal * (penetration * 0.5)
  // Invert normal for collision response direction
  // Convention: normal points FROM body_a TO body_b
  // When invert_normal=true, cylinder is body_a, so normal should point toward sphere (negate surface normal)
  if !invert_normal do normal = -normal
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
  invert_normal: bool = false,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  obb := geometry.Obb {
    center       = pos_box,
    half_extents = box.half_extents,
    rotation     = rot_box,
  }
  point, normal, penetration, hit = geometry.obb_cylinder_intersect(
    obb,
    pos_cylinder,
    rot_cylinder,
    cylinder.radius,
    cylinder.height,
  )
  if invert_normal && hit do normal = -normal
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
  local_b_center := geometry.qmv(inv_rot_a, to_b)
  // Cylinder B's axis in cylinder A's local space
  b_axis_world := geometry.qmv(rot_b, linalg.VECTOR3F32_Y_AXIS)
  b_axis_local := geometry.qmv(inv_rot_a, b_axis_world)
  // Check if axes are parallel
  parallel := math.abs(math.abs(b_axis_local.y) - 1.0) < 0.01
  if parallel {
    // Axes are parallel - treat as 2D circle-circle in XZ plane
    radial := [3]f32{local_b_center.x, 0, local_b_center.z}
    radial_dist := linalg.length(radial)
    radius_sum := cylinder_a.radius + cylinder_b.radius
    if radial_dist > radius_sum {
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
    normal = geometry.qmv(rot_a, local_normal)
    point = pos_a + geometry.qmv(rot_a, local_point)
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
  if dist_sq > radius_sum * radius_sum {
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
  switch shape_a in collider_a {
  case FanCollider:
    return
  case SphereCollider:
    switch shape_b in collider_b {
    case FanCollider:
      return
    case SphereCollider:
      return test_sphere_sphere(pos_a, shape_a, pos_b, shape_b)
    case BoxCollider:
      return test_box_sphere(
        pos_b,
        rot_b,
        shape_b,
        pos_a,
        shape_a,
        invert_normal = true,
      )
    case CylinderCollider:
      return test_sphere_cylinder(pos_a, shape_a, pos_b, rot_b, shape_b)
    }
  case BoxCollider:
    switch shape_b in collider_b {
    case FanCollider:
      return
    case SphereCollider:
      return test_box_sphere(pos_a, rot_a, shape_a, pos_b, shape_b)
    case BoxCollider:
      return test_box_box(pos_a, rot_a, shape_a, pos_b, rot_b, shape_b)
    case CylinderCollider:
      return test_box_cylinder(
        pos_a,
        rot_a,
        shape_a,
        pos_b,
        rot_b,
        shape_b,
      )
    }
  case CylinderCollider:
    switch shape_b in collider_b {
    case FanCollider:
      return
    case SphereCollider:
      return test_sphere_cylinder(
        pos_b,
        shape_b,
        pos_a,
        rot_a,
        shape_a,
        invert_normal = true,
      )
    case BoxCollider:
      return test_box_cylinder(
        pos_b,
        rot_b,
        shape_b,
        pos_a,
        rot_a,
        shape_a,
        invert_normal = true,
      )
    case CylinderCollider:
      return test_cylinder_cylinder(
        pos_a,
        rot_a,
        shape_a,
        pos_b,
        rot_b,
        shape_b,
      )
    }
  }
  return
}

test_collision_gjk :: proc(
  collider_a, collider_b: ^Collider,
  pos_a, pos_b: [3]f32,
  rot_a, rot_b: quaternion128,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  simplex: Simplex
  if !gjk(collider_a, collider_b, pos_a, pos_b, rot_a, rot_b, &simplex) {
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
  point = pos_a + normal * penetration * 0.5
  return
}
