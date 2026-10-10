package physics

import cont "../containers"
import "../geometry"
import "core:math"
import "core:math/linalg"

// Physics raycast hit result
RayHit :: struct {
  body_handle: BodyHandleResult,
  t:           f32,
  point:       [3]f32,
  normal:      [3]f32,
  hit:         bool,
}

// Union type for raycast results (can hit either dynamic or static bodies)
BodyHandleResult :: union {
  DynamicRigidBodyHandle,
  StaticRigidBodyHandle,
  TriggerHandle,
}

// Test ray against one BVH's candidates, tightening `closest` in place.
// first_hit stops at the first intersection (any-hit query).
// Returns true if a hit was recorded.
@(private = "file")
raycast_candidates :: proc(
  self: ^World,
  candidates: []$E,
  ray: geometry.Ray,
  closest: ^RayHit,
  first_hit: bool,
) -> (found: bool) {
  for candidate in candidates {
    body := get(self, candidate.handle) or_continue
    t, normal, hit := raycast_collider(
      ray,
      &body.collider,
      body.position,
      body.rotation,
      closest.t,
    )
    if hit && t < closest.t {
      closest^ = {
        body_handle = candidate.handle,
        t           = t,
        point       = ray.origin + ray.direction * t,
        normal      = normal,
        hit         = true,
      }
      found = true
      if first_hit do return
    }
  }
  return
}

// Physics raycast - finds closest body hit by ray.
// first_hit = true returns the first intersection found instead (early exit).
raycast :: proc(
  self: ^World,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
  first_hit := false,
) -> RayHit {
  closest_hit := RayHit {
    hit = false,
    t   = max_dist,
  }
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    context.temp_allocator,
  )
  geometry.bvh_query_ray(&self.dynamic_bvh, ray, max_dist, &dyn_candidates)
  if raycast_candidates(self, dyn_candidates[:], ray, &closest_hit, first_hit) && first_hit {
    return closest_hit
  }
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    context.temp_allocator,
  )
  geometry.bvh_query_ray(&self.static_bvh, ray, max_dist, &static_candidates)
  raycast_candidates(self, static_candidates[:], ray, &closest_hit, first_hit)
  return closest_hit
}

// Physics raycast - finds any body hit by ray (early exit)
raycast_single :: proc(
  self: ^World,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
) -> RayHit {
  return raycast(self, ray, max_dist, first_hit = true)
}

// Raycast against trigger bodies only — linear scan over trigger pool
raycast_trigger :: proc(
  self: ^World,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
) -> RayHit {
  closest_hit := RayHit {
    hit = false,
    t   = max_dist,
  }
  inv_dir := 1.0 / ray.direction
  it := cont.iterator(&self.trigger_bodies)
  for trigger, handle in cont.next(&it, TriggerHandle) {
    // Broad phase: ray vs cached AABB
    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      inv_dir,
      trigger.cached_aabb,
    )
    if t_near > t_far || t_far < 0 || t_near > closest_hit.t do continue
    // Narrow phase
    t, normal, hit := raycast_collider(
      ray,
      &trigger.collider,
      trigger.position,
      trigger.rotation,
      closest_hit.t,
    )
    if hit && t < closest_hit.t {
      closest_hit.body_handle = handle
      closest_hit.t = t
      closest_hit.point = ray.origin + ray.direction * t
      closest_hit.normal = normal
      closest_hit.hit = true
    }
  }
  return closest_hit
}

// Raycast against a specific collider. The ray is tested in the collider's
// local frame (Y = cylinder/fan axis, fan forward = +Z) and the hit normal
// rotated back to world space. A ray starting inside the shape hits at t = 0.
@(private)
raycast_collider :: proc(
  ray: geometry.Ray,
  collider: ^Collider,
  position: [3]f32,
  rotation: quaternion128,
  max_dist: f32,
) -> (
  t: f32,
  normal: [3]f32,
  hit: bool,
) {
  if sphere, is_sphere := collider.(SphereCollider); is_sphere {
    hit, t = geometry.ray_sphere_intersection(
      ray,
      geometry.Sphere{center = position, radius = sphere.radius},
      max_dist,
    )
    if hit do normal = linalg.normalize(ray.origin + ray.direction * t - position)
    return
  }
  inv_rot := linalg.quaternion_inverse(rotation)
  local := geometry.Ray {
    origin    = geometry.qmv(inv_rot, ray.origin - position),
    direction = geometry.qmv(inv_rot, ray.direction),
  }
  local_normal: [3]f32
  #partial switch shape in collider {
  case BoxCollider:
    t, local_normal, hit = raycast_local_box(local, shape.half_extents)
  case CylinderCollider:
    t, local_normal, hit = raycast_local_fan(local, shape.radius, shape.height, 2 * math.PI)
  case FanCollider:
    t, local_normal, hit = raycast_local_fan(local, shape.radius, shape.height, shape.angle)
  }
  if !hit || t > max_dist do return 0, {}, false
  return t, geometry.qmv(rotation, local_normal), true
}

@(private = "file")
raycast_local_box :: proc(
  ray: geometry.Ray,
  half_extents: [3]f32,
) -> (
  t: f32,
  normal: [3]f32,
  hit: bool,
) {
  box := geometry.Aabb{-half_extents, half_extents}
  t_near, t_far := geometry.ray_aabb_intersection(ray.origin, 1.0 / ray.direction, box)
  if t_near > t_far || t_far < 0 do return
  t = max(0, t_near)
  return t, geometry.aabb_face_normal(box, ray.origin + ray.direction * t), true
}

// Ray vs a cylinder sector centered on the origin: axis Y, sector of `angle`
// radians centered on +Z (angle >= 2*PI is a full cylinder). Takes the
// nearest hit among caps, curved wall and the two side planes, each clipped
// to the solid.
@(private = "file")
raycast_local_fan :: proc(
  ray: geometry.Ray,
  radius, height, angle: f32,
) -> (
  t: f32,
  normal: [3]f32,
  hit: bool,
) {
  half_h := height * 0.5
  half_angle := angle * 0.5
  full := angle >= 2 * math.PI
  in_sector :: proc(p: [3]f32, half_angle: f32, full: bool) -> bool {
    if full || linalg.length2(p.xz) < 1e-12 do return true
    return math.abs(math.atan2(p.x, p.z)) <= half_angle + 1e-5
  }
  inside :=
    linalg.length2(ray.origin.xz) <= radius * radius &&
    math.abs(ray.origin.y) <= half_h &&
    in_sector(ray.origin, half_angle, full)
  if inside do return 0, -linalg.normalize(ray.direction), true
  t = max(f32)
  try :: proc(s: f32, n: [3]f32, t: ^f32, normal: ^[3]f32, hit: ^bool) {
    if s >= 0 && s < t^ {
      t^ = s
      normal^ = n
      hit^ = true
    }
  }
  // Caps
  if math.abs(ray.direction.y) > 1e-8 {
    for side in ([2]f32{-1, 1}) {
      s := (side * half_h - ray.origin.y) / ray.direction.y
      p := ray.origin + ray.direction * s
      if linalg.length2(p.xz) <= radius * radius && in_sector(p, half_angle, full) {
        try(s, {0, side, 0}, &t, &normal, &hit)
      }
    }
  }
  // Curved wall: |o.xz + s*d.xz|^2 = r^2, entering root
  a := linalg.length2(ray.direction.xz)
  if a > 1e-12 {
    b := linalg.dot(ray.origin.xz, ray.direction.xz)
    c := linalg.length2(ray.origin.xz) - radius * radius
    disc := b * b - a * c
    if disc >= 0 {
      s := (-b - math.sqrt(disc)) / a
      p := ray.origin + ray.direction * s
      if math.abs(p.y) <= half_h && in_sector(p, half_angle, full) {
        try(s, {p.x / radius, 0, p.z / radius}, &t, &normal, &hit)
      }
    }
  }
  // Side planes through the axis at +-half_angle from +Z
  if !full {
    for sign in ([2]f32{-1, 1}) {
      phi := sign * half_angle
      dir := [3]f32{math.sin(phi), 0, math.cos(phi)} // edge direction in XZ
      n := [3]f32{dir.z, 0, -dir.x} * sign // outward, away from the sector
      denom := linalg.dot(n, ray.direction)
      if math.abs(denom) < 1e-8 do continue
      s := -linalg.dot(n, ray.origin) / denom
      p := ray.origin + ray.direction * s
      along := linalg.dot(p, dir)
      if along >= 0 && along <= radius && math.abs(p.y) <= half_h {
        try(s, n, &t, &normal, &hit)
      }
    }
  }
  if !hit do t = 0
  return
}

// Query sphere - finds all bodies within a sphere
query_sphere :: proc(
  self: ^World,
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]DynamicRigidBodyHandle,
) {
  clear(results)
  query_bounds := geometry.Aabb {
    min = center - [3]f32{radius, radius, radius},
    max = center + [3]f32{radius, radius, radius},
  }
  // Only query dynamic bodies (static bodies don't need sphere queries typically)
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    context.temp_allocator,
  )
  geometry.bvh_query_aabb(&self.dynamic_bvh, query_bounds, &dyn_candidates)
  for candidate in dyn_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    if test_collider_sphere_overlap(
      collider,
      body.position,
      body.rotation,
      center,
      radius,
    ) {
      append(results, candidate.handle)
    }
  }
}

// Query box - finds all bodies within an AABB
query_box :: proc(
  self: ^World,
  bounds: geometry.Aabb,
  results: ^[dynamic]DynamicRigidBodyHandle,
) {
  clear(results)
  // Only query dynamic bodies
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    context.temp_allocator,
  )
  geometry.bvh_query_aabb(&self.dynamic_bvh, bounds, &dyn_candidates)
  for candidate in dyn_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    if test_collider_aabb_overlap(
      collider,
      body.position,
      body.rotation,
      bounds,
    ) {
      append(results, candidate.handle)
    }
  }
}

// Query a single trigger against dynamic bodies — on-demand variant of trigger_overlaps
query_trigger :: proc(
  self: ^World,
  handle: TriggerHandle,
  results: ^[dynamic]DynamicRigidBodyHandle,
) {
  clear(results)
  trigger, ok := get_trigger(self, handle)
  if !ok do return
  dyn_candidates := make(
    [dynamic]DynamicBroadPhaseEntry,
    context.temp_allocator,
  )
  geometry.bvh_query_aabb(&self.dynamic_bvh, trigger.cached_aabb, &dyn_candidates)
  for candidate in dyn_candidates {
    body := get(self, candidate.handle) or_continue
    if body.is_killed do continue
    _, hit := collide(
      &trigger.collider,
      trigger.position,
      trigger.rotation,
      &body.collider,
      body.position,
      body.rotation,
    )
    if hit {
      append(results, candidate.handle)
    }
  }
}

// Query a single trigger against static bodies — on-demand variant of trigger_static_overlaps
query_trigger_static :: proc(
  self: ^World,
  handle: TriggerHandle,
  results: ^[dynamic]StaticRigidBodyHandle,
) {
  clear(results)
  trigger, ok := get_trigger(self, handle)
  if !ok do return
  static_candidates := make(
    [dynamic]StaticBroadPhaseEntry,
    context.temp_allocator,
  )
  geometry.bvh_query_aabb(
    &self.static_bvh,
    trigger.cached_aabb,
    &static_candidates,
  )
  for candidate in static_candidates {
    body := get(self, candidate.handle) or_continue
    _, hit := collide(
      &trigger.collider,
      trigger.position,
      trigger.rotation,
      &body.collider,
      body.position,
      body.rotation,
    )
    if hit {
      append(results, candidate.handle)
    }
  }
}

// Find all triggers whose colliders overlap a given sphere
query_triggers_in_sphere :: proc(
  self: ^World,
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]TriggerHandle,
) {
  clear(results)
  it := cont.iterator(&self.trigger_bodies)
  for trigger, handle in cont.next(&it, TriggerHandle) {
    // Broad phase: bounding sphere check
    bounding_spheres_intersect(
      trigger.cached_sphere_center,
      trigger.cached_sphere_radius,
      center,
      radius,
    ) or_continue
    // Narrow phase: collider vs sphere
    if test_collider_sphere_overlap(
      &trigger.collider,
      trigger.position,
      trigger.rotation,
      center,
      radius,
    ) {
      append(results, handle)
    }
  }
}

// Test if collider overlaps with sphere
@(private)
test_collider_sphere_overlap :: proc(
  collider: ^Collider,
  collider_pos: [3]f32,
  collider_rot: quaternion128,
  sphere_center: [3]f32,
  sphere_radius: f32,
) -> bool {
  switch shape in collider {
  case SphereCollider:
    len := shape.radius + sphere_radius
    return linalg.length2(collider_pos - sphere_center) <= len * len
  case BoxCollider:
    obb := geometry.Obb {
      center       = collider_pos,
      half_extents = shape.half_extents,
      rotation     = collider_rot,
    }
    _, _, _, hit := geometry.obb_sphere_intersect(
      obb,
      sphere_center,
      sphere_radius,
    )
    return hit
  case CylinderCollider:
    return test_point_cylinder(
      sphere_center,
      collider_pos,
      collider_rot,
      shape,
    )
  case FanCollider:
    return test_point_fan(sphere_center, collider_pos, collider_rot, shape)
  }
  return false
}

// Test if collider overlaps with AABB
@(private)
test_collider_aabb_overlap :: proc(
  collider: ^Collider,
  collider_pos: [3]f32,
  collider_rot: quaternion128,
  bounds: geometry.Aabb,
) -> bool {
  // Use center point test for now - could be more precise
  return geometry.aabb_contains_point(bounds, collider_pos)
}
