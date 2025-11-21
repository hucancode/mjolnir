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
  body_a:          resources.Handle,
  body_b:          resources.Handle,
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

CollisionPair :: struct {
  body_a: resources.Handle,
  body_b: resources.Handle,
}

// Hash function for collision pairs (for contact caching)
collision_pair_hash :: proc "contextless" (pair: CollisionPair) -> u64 {
  // Ensure consistent ordering: smaller index first
  a := min(pair.body_a.index, pair.body_b.index)
  b := max(pair.body_a.index, pair.body_b.index)
  return (u64(a) << 32) | u64(b)
}

collision_pair_eq :: proc "contextless" (
  a: CollisionPair,
  b: CollisionPair,
) -> bool {
  return(
    (a.body_a == b.body_a && a.body_b == b.body_b) ||
    (a.body_a == b.body_b && a.body_b == b.body_a) \
  )
}

test_sphere_sphere :: proc(
  pos_a: [3]f32,
  sphere_a: ^SphereCollider,
  pos_b: [3]f32,
  sphere_b: ^SphereCollider,
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
  box_a: ^BoxCollider,
  pos_b: [3]f32,
  box_b: ^BoxCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  is_a_aligned := is_identity_quaternion(box_a.rotation)
  is_b_aligned := is_identity_quaternion(box_b.rotation)
  // Fast path for axis-aligned boxes
  if is_a_aligned && is_b_aligned {
    min_a := pos_a - box_a.half_extents
    max_a := pos_a + box_a.half_extents
    min_b := pos_b - box_b.half_extents
    max_b := pos_b + box_b.half_extents
    if max_a.x < min_b.x || min_a.x > max_b.x do return
    if max_a.y < min_b.y || min_a.y > max_b.y do return
    if max_a.z < min_b.z || min_a.z > max_b.z do return
    overlap_x := math.min(max_a.x, max_b.x) - math.max(min_a.x, min_b.x)
    overlap_y := math.min(max_a.y, max_b.y) - math.max(min_a.y, min_b.y)
    overlap_z := math.min(max_a.z, max_b.z) - math.max(min_a.z, min_b.z)
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
      normal = pos_b.y > pos_a.y ? {0, 1, 0} : {0, -1, 0}
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
    rotation     = box_a.rotation,
  }
  obb_b := geometry.Obb {
    center       = pos_b,
    half_extents = box_b.half_extents,
    rotation     = box_b.rotation,
  }
  return geometry.obb_obb_intersect(obb_a, obb_b)
}

test_sphere_box :: proc(
  pos_sphere: [3]f32,
  sphere: ^SphereCollider,
  pos_box: [3]f32,
  box: ^BoxCollider,
) -> (
  closest: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  is_aligned := is_identity_quaternion(box.rotation)
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
    rotation     = box.rotation,
  }
  return geometry.obb_sphere_intersect(obb, pos_sphere, sphere.radius)
}

test_capsule_capsule :: proc(
  pos_a: [3]f32,
  capsule_a: ^CapsuleCollider,
  pos_b: [3]f32,
  capsule_b: ^CapsuleCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  h_a := capsule_a.height * 0.5
  h_b := capsule_b.height * 0.5
  line_a_start := pos_a + [3]f32{0, -h_a, 0}
  line_a_end := pos_a + [3]f32{0, h_a, 0}
  line_b_start := pos_b + [3]f32{0, -h_b, 0}
  line_b_end := pos_b + [3]f32{0, h_b, 0}
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

test_sphere_capsule :: proc(
  pos_sphere: [3]f32,
  sphere: ^SphereCollider,
  pos_capsule: [3]f32,
  capsule: ^CapsuleCollider,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  h := capsule.height * 0.5
  line_start := pos_capsule + [3]f32{0, -h, 0}
  line_end := pos_capsule + [3]f32{0, h, 0}
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
  box: ^BoxCollider,
  pos_capsule: [3]f32,
  capsule: ^CapsuleCollider,
) -> (
  closest: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  is_aligned := is_identity_quaternion(box.rotation)
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
  // OBB case
  obb := geometry.Obb {
    center       = pos_box,
    half_extents = box.half_extents,
    rotation     = box.rotation,
  }
  closest, normal, penetration, hit = geometry.obb_capsule_intersect(
    obb,
    pos_capsule,
    capsule.radius,
    capsule.height,
  )
  return
}

// Point-in-cylinder test - checks if point is inside a cylinder
test_point_cylinder :: proc(
  point: [3]f32,
  cylinder_center: [3]f32,
  cylinder: ^CylinderCollider,
) -> bool {
  // Transform point to cylinder's local space
  local_point := point - cylinder_center
  // Rotate point by inverse of cylinder's rotation
  inv_rot := linalg.quaternion_inverse(cylinder.rotation)
  local_point = linalg.mul(inv_rot, local_point)
  // In local space, cylinder axis is Y, check radial distance and height
  radial_dist_sq := local_point.x * local_point.x + local_point.z * local_point.z
  half_height := cylinder.height * 0.5
  return radial_dist_sq <= cylinder.radius * cylinder.radius && math.abs(local_point.y) <= half_height
}

// Point-in-fan test - checks if point is inside a fan (partial cylinder)
test_point_fan :: proc(
  point: [3]f32,
  fan_center: [3]f32,
  fan: ^FanCollider,
) -> bool {
  // Transform point to fan's local space
  local_point := point - fan_center
  // Rotate point by inverse of fan's rotation
  inv_rot := linalg.quaternion_inverse(fan.rotation)
  local_point = linalg.mul(inv_rot, local_point)
  // In local space, fan forward direction is +Z, axis is Y
  // Check radial distance and height first (like cylinder)
  radial_dist_sq := local_point.x * local_point.x + local_point.z * local_point.z
  half_height := fan.height * 0.5
  if radial_dist_sq > fan.radius * fan.radius || math.abs(local_point.y) > half_height {
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

test_collision :: proc(
  collider_a: ^Collider,
  pos_a: [3]f32,
  collider_b: ^Collider,
  pos_b: [3]f32,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  center_a := pos_a + collider_a.offset
  center_b := pos_b + collider_b.offset
  // Fan is trigger-only, no collision resolution
  // Cylinder can be solid and uses GJK fallback
  if collider_a.type == .Fan || collider_b.type == .Fan {
    return {}, {}, 0, false
  }
  if collider_a.type == .Sphere && collider_b.type == .Sphere {
    sphere_a := &collider_a.shape.(SphereCollider)
    sphere_b := &collider_b.shape.(SphereCollider)
    return test_sphere_sphere(center_a, sphere_a, center_b, sphere_b)
  } else if collider_a.type == .Box && collider_b.type == .Box {
    box_a := &collider_a.shape.(BoxCollider)
    box_b := &collider_b.shape.(BoxCollider)
    return test_box_box(center_a, box_a, center_b, box_b)
  } else if collider_a.type == .Sphere && collider_b.type == .Box {
    sphere := &collider_a.shape.(SphereCollider)
    box := &collider_b.shape.(BoxCollider)
    point, normal, penetration, hit = test_sphere_box(
      center_a,
      sphere,
      center_b,
      box,
    )
    // invert normal because test_sphere_box return normal pointing box -> sphere
    normal = -normal
    return
  } else if collider_a.type == .Box && collider_b.type == .Sphere {
    box := &collider_a.shape.(BoxCollider)
    sphere := &collider_b.shape.(SphereCollider)
    return test_sphere_box(center_b, sphere, center_a, box)
  } else if collider_a.type == .Capsule && collider_b.type == .Capsule {
    capsule_a := &collider_a.shape.(CapsuleCollider)
    capsule_b := &collider_b.shape.(CapsuleCollider)
    return test_capsule_capsule(center_a, capsule_a, center_b, capsule_b)
  } else if collider_a.type == .Sphere && collider_b.type == .Capsule {
    sphere := &collider_a.shape.(SphereCollider)
    capsule := &collider_b.shape.(CapsuleCollider)
    point, normal, penetration, hit = test_sphere_capsule(
      center_a,
      sphere,
      center_b,
      capsule,
    )
    // invert normal because test_sphere_capsule return normal pointing capsule -> sphere
    normal = -normal
    return
  } else if collider_a.type == .Capsule && collider_b.type == .Sphere {
    capsule := &collider_a.shape.(CapsuleCollider)
    sphere := &collider_b.shape.(SphereCollider)
    return test_sphere_capsule(center_b, sphere, center_a, capsule)
  } else if collider_a.type == .Box && collider_b.type == .Capsule {
    box := &collider_a.shape.(BoxCollider)
    capsule := &collider_b.shape.(CapsuleCollider)
    return test_box_capsule(center_a, box, center_b, capsule)
  } else if collider_a.type == .Capsule && collider_b.type == .Box {
    capsule := &collider_a.shape.(CapsuleCollider)
    box := &collider_b.shape.(BoxCollider)
    point, normal, penetration, hit = test_box_capsule(
      center_b,
      box,
      center_a,
      capsule,
    )
    // invert normal because test_box_capsule return normal pointing box -> capsule
    normal = -normal
    return
  }
  return
}

test_collision_gjk :: proc(
  collider_a: ^Collider,
  pos_a: [3]f32,
  collider_b: ^Collider,
  pos_b: [3]f32,
) -> (
  point: [3]f32,
  normal: [3]f32,
  penetration: f32,
  hit: bool,
) {
  simplex: Simplex
  if !gjk(collider_a, pos_a, collider_b, pos_b, &simplex) {
    return
  }
  normal, penetration, hit = epa(simplex, collider_a, pos_a, collider_b, pos_b)
  if !hit {
    return
  }
  center_a := pos_a + collider_a.offset
  center_b := pos_b + collider_b.offset
  point = center_a + normal * penetration * 0.5
  return
}
