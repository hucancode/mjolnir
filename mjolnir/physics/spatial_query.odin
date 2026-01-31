package physics

import cont "../containers"
import "../geometry"
import "../resources"
import "core:log"
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
}

// Physics raycast - finds closest body hit by ray
raycast :: proc(
  self: ^World,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
) -> RayHit {
  closest_hit := RayHit {
    hit = false,
    t   = max_dist,
  }
  // Query dynamic BVH
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, context.temp_allocator)
  bvh_query_ray_fast(&self.dynamic_bvh, ray, max_dist, &dyn_candidates)
  for candidate in dyn_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    t, normal, hit := raycast_collider(ray, collider, body.position, body.rotation, closest_hit.t)
    if hit && t < closest_hit.t {
      closest_hit.body_handle = candidate.handle
      closest_hit.t = t
      closest_hit.point = ray.origin + ray.direction * t
      closest_hit.normal = normal
      closest_hit.hit = true
    }
  }
  // Query static BVH
  static_candidates := make([dynamic]StaticBroadPhaseEntry, context.temp_allocator)
  bvh_query_ray_fast(&self.static_bvh, ray, max_dist, &static_candidates)
  for candidate in static_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    t, normal, hit := raycast_collider(ray, collider, body.position, body.rotation, closest_hit.t)
    if hit && t < closest_hit.t {
      closest_hit.body_handle = candidate.handle
      closest_hit.t = t
      closest_hit.point = ray.origin + ray.direction * t
      closest_hit.normal = normal
      closest_hit.hit = true
    }
  }
  return closest_hit
}

// Physics raycast - finds any body hit by ray (early exit)
raycast_single :: proc(
  self: ^World,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
) -> RayHit {
  // Query dynamic BVH
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, context.temp_allocator)
  bvh_query_ray_fast(&self.dynamic_bvh, ray, max_dist, &dyn_candidates)
  for candidate in dyn_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    t, normal, hit := raycast_collider(ray, collider, body.position, body.rotation, max_dist)
    if hit {
      return RayHit {
        body_handle = candidate.handle,
        t = t,
        point = ray.origin + ray.direction * t,
        normal = normal,
        hit = true,
      }
    }
  }
  // Query static BVH
  static_candidates := make([dynamic]StaticBroadPhaseEntry, context.temp_allocator)
  bvh_query_ray_fast(&self.static_bvh, ray, max_dist, &static_candidates)
  for candidate in static_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    t, normal, hit := raycast_collider(ray, collider, body.position, body.rotation, max_dist)
    if hit {
      return RayHit {
        body_handle = candidate.handle,
        t = t,
        point = ray.origin + ray.direction * t,
        normal = normal,
        hit = true,
      }
    }
  }
  return {}
}

// Raycast against a specific collider
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
  switch shape in collider.shape {
  case SphereCollider:
    sphere_prim := geometry.Sphere {
      center = position,
      radius = shape.radius,
    }
    hit, t = geometry.ray_sphere_intersection(ray, sphere_prim, max_dist)
    if hit {
      hit_point := ray.origin + ray.direction * t
      normal = linalg.normalize(hit_point - position)
    }
    return t, normal, hit
  case BoxCollider:
    obb := geometry.Obb {
      center       = position,
      half_extents = shape.half_extents,
      rotation     = rotation,
    }
    // Use AABB intersection for axis-aligned boxes
    if is_identity_quaternion(rotation) {
      bounds := geometry.Aabb {
        min = position - shape.half_extents,
        max = position + shape.half_extents,
      }
      inv_dir := 1.0 / ray.direction
      t_near, t_far := geometry.ray_aabb_intersection(
        ray.origin,
        inv_dir,
        bounds,
      )
      if t_near <= t_far && t_far >= 0 && t_near <= max_dist {
        t = max(0, t_near)
        hit_point := ray.origin + ray.direction * t
        // Compute normal based on which face was hit
        epsilon :: 0.0001
        if math.abs(hit_point.x - bounds.min.x) < epsilon do normal = -linalg.VECTOR3F32_X_AXIS
        else if math.abs(hit_point.x - bounds.max.x) < epsilon do normal = linalg.VECTOR3F32_X_AXIS
        else if math.abs(hit_point.y - bounds.min.y) < epsilon do normal = -linalg.VECTOR3F32_Y_AXIS
        else if math.abs(hit_point.y - bounds.max.y) < epsilon do normal = linalg.VECTOR3F32_Y_AXIS
        else if math.abs(hit_point.z - bounds.min.z) < epsilon do normal = -linalg.VECTOR3F32_Z_AXIS
        else if math.abs(hit_point.z - bounds.max.z) < epsilon do normal = linalg.VECTOR3F32_Z_AXIS
        return t, normal, true
      }
      return 0, {}, false
    }
    // For rotated boxes, test via GJK (expensive fallback)
    // For now, just test AABB
    bounds := geometry.obb_to_aabb(obb)
    inv_dir := [3]f32 {
      1.0 / ray.direction.x,
      1.0 / ray.direction.y,
      1.0 / ray.direction.z,
    }
    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      inv_dir,
      bounds,
    )
    if t_near <= t_far && t_far >= 0 && t_near <= max_dist {
      t = max(0, t_near)
      return t, linalg.VECTOR3F32_Y_AXIS, true // approximate normal
    }
    return 0, {}, false
  case CylinderCollider, FanCollider:
    // Cylinder and Fan use GJK for collision, but for raycasting we'll use a simplified approach
    // Transform to AABB for now
    bounds := collider_calculate_aabb(collider, position, rotation)
    inv_dir := 1.0 / ray.direction
    t_near, t_far := geometry.ray_aabb_intersection(
      ray.origin,
      inv_dir,
      bounds,
    )
    if t_near <= t_far && t_far >= 0 && t_near <= max_dist {
      t = max(0, t_near)
      return t, linalg.VECTOR3F32_Y_AXIS, true // approximate normal
    }
    return 0, {}, false
  }
  return 0, {}, false
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
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, context.temp_allocator)
  bvh_query_aabb_fast(&self.dynamic_bvh, query_bounds, &dyn_candidates)
  for candidate in dyn_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    if test_collider_sphere_overlap(collider, body.position, body.rotation, center, radius) {
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
  dyn_candidates := make([dynamic]DynamicBroadPhaseEntry, context.temp_allocator)
  bvh_query_aabb_fast(&self.dynamic_bvh, bounds, &dyn_candidates)
  for candidate in dyn_candidates {
    body := get(self, candidate.handle) or_continue
    collider := &body.collider
    if test_collider_aabb_overlap(collider, body.position, body.rotation, bounds) {
      append(results, candidate.handle)
    }
  }
}

// Test if collider overlaps with sphere
test_collider_sphere_overlap :: proc(
  collider: ^Collider,
  collider_pos: [3]f32,
  collider_rot: quaternion128,
  sphere_center: [3]f32,
  sphere_radius: f32,
) -> bool {
  switch shape in collider.shape {
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
    return test_point_cylinder(sphere_center, collider_pos, collider_rot, shape)
  case FanCollider:
    return test_point_fan(sphere_center, collider_pos, collider_rot, shape)
  }
  return false
}

// Test if collider overlaps with AABB
test_collider_aabb_overlap :: proc(
  collider: ^Collider,
  collider_pos: [3]f32,
  collider_rot: quaternion128,
  bounds: geometry.Aabb,
) -> bool {
  // Use center point test for now - could be more precise
  return geometry.aabb_contains_point(bounds, collider_pos)
}
