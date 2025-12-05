package physics

import cont "../containers"
import "../geometry"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"

// Physics raycast hit result
PhysicsRayHit :: struct {
  body_handle: RigidBodyHandle,
  t:           f32,
  point:       [3]f32,
  normal:      [3]f32,
  hit:         bool,
}

// Physics raycast - finds closest body hit by ray
physics_raycast :: proc(
  physics: ^PhysicsWorld,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
) -> PhysicsRayHit {
  closest_hit := PhysicsRayHit {
    hit = false,
    t   = max_dist,
  }
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  bvh_query_ray_fast(&physics.spatial_index, ray, max_dist, &candidates)
  for candidate in candidates {
    body := cont.get(physics.bodies, candidate.handle) or_continue
    if body.collider_handle.generation == 0 do continue
    collider := cont.get(physics.colliders, body.collider_handle) or_continue
    pos := body.position
    // Narrow phase - test actual collider shape
    t, normal, hit := raycast_collider(ray, collider, pos, closest_hit.t)
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
physics_raycast_single :: proc(
  physics: ^PhysicsWorld,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
) -> PhysicsRayHit {
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  bvh_query_ray_fast(&physics.spatial_index, ray, max_dist, &candidates)
  for candidate in candidates {
    body := cont.get(physics.bodies, candidate.handle) or_continue
    if body.collider_handle.generation == 0 do continue
    collider := cont.get(physics.colliders, body.collider_handle) or_continue
    pos := body.position
    // Narrow phase - test actual collider shape
    t, normal, hit := raycast_collider(ray, collider, pos, max_dist)
    if hit {
      return PhysicsRayHit {
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
  max_dist: f32,
) -> (
  t: f32,
  normal: [3]f32,
  hit: bool,
) {
  center := position + collider.offset
  switch shape in collider.shape {
  case SphereCollider:
    sphere_prim := geometry.Sphere {
      center = center,
      radius = shape.radius,
    }
    hit, t = geometry.ray_sphere_intersection(ray, sphere_prim, max_dist)
    if hit {
      hit_point := ray.origin + ray.direction * t
      normal = linalg.normalize(hit_point - center)
    }
    return t, normal, hit
  case BoxCollider:
    obb := geometry.Obb {
      center       = center,
      half_extents = shape.half_extents,
      rotation     = shape.rotation,
    }
    // Use AABB intersection for axis-aligned boxes
    if is_identity_quaternion(shape.rotation) {
      bounds := geometry.Aabb {
        min = center - shape.half_extents,
        max = center + shape.half_extents,
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
  case CapsuleCollider:
    h := shape.height * 0.5
    line_start := center + [3]f32{0, -h, 0}
    line_end := center + [3]f32{0, h, 0}
    // Raycast as sphere sweep along line segment
    // Find closest point on segment to ray
    // For now, use simplified approach: test sphere at each endpoint
    s1 := geometry.Sphere {
      center = line_start,
      radius = shape.radius,
    }
    s2 := geometry.Sphere {
      center = line_end,
      radius = shape.radius,
    }
    hit1, t1 := geometry.ray_sphere_intersection(ray, s1, max_dist)
    hit2, t2 := geometry.ray_sphere_intersection(ray, s2, max_dist)
    if hit1 && hit2 {
      t = min(t1, t2)
      hit_point := ray.origin + ray.direction * t
      sphere_center := t == t1 ? line_start : line_end
      normal = linalg.normalize(hit_point - sphere_center)
      return t, normal, true
    } else if hit1 {
      t = t1
      hit_point := ray.origin + ray.direction * t
      normal = linalg.normalize(hit_point - line_start)
      return t, normal, true
    } else if hit2 {
      t = t2
      hit_point := ray.origin + ray.direction * t
      normal = linalg.normalize(hit_point - line_end)
      return t, normal, true
    }
    return 0, {}, false
  case CylinderCollider, FanCollider:
    // Cylinder and Fan use GJK for collision, but for raycasting we'll use a simplified approach
    // Transform to AABB for now
    bounds := collider_calculate_aabb(collider, position)
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
physics_query_sphere :: proc(
  physics: ^PhysicsWorld,
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]RigidBodyHandle,
) {
  clear(results)
  query_bounds := geometry.Aabb {
    min = center - [3]f32{radius, radius, radius},
    max = center + [3]f32{radius, radius, radius},
  }
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  bvh_query_aabb_fast(&physics.spatial_index, query_bounds, &candidates)
  for candidate in candidates {
    body := cont.get(physics.bodies, candidate.handle) or_continue
    collider := cont.get(physics.colliders, body.collider_handle) or_continue
    pos := body.position
    // Test if collider is within sphere
    if test_collider_sphere_overlap(collider, pos, center, radius) {
      append(results, candidate.handle)
    }
  }
}

// Query box - finds all bodies within an AABB
physics_query_box :: proc(
  physics: ^PhysicsWorld,
  bounds: geometry.Aabb,
  results: ^[dynamic]RigidBodyHandle,
) {
  clear(results)
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  bvh_query_aabb_fast(&physics.spatial_index, bounds, &candidates)
  for candidate in candidates {
    body := cont.get(physics.bodies, candidate.handle) or_continue
    collider := cont.get(physics.colliders, body.collider_handle) or_continue
    pos := body.position
    // Test if collider is within box
    if test_collider_aabb_overlap(collider, pos, bounds) {
      append(results, candidate.handle)
    }
  }
}

// Test if collider overlaps with sphere
test_collider_sphere_overlap :: proc(
  collider: ^Collider,
  collider_pos: [3]f32,
  sphere_center: [3]f32,
  sphere_radius: f32,
) -> bool {
  center := collider_pos + collider.offset
  switch shape in collider.shape {
  case SphereCollider:
    len := shape.radius + sphere_radius
    return linalg.length2(center - sphere_center) <= len * len
  case BoxCollider:
    obb := geometry.Obb {
      center       = center,
      half_extents = shape.half_extents,
      rotation     = shape.rotation,
    }
    _, _, _, hit := geometry.obb_sphere_intersect(
      obb,
      sphere_center,
      sphere_radius,
    )
    return hit
  case CapsuleCollider:
    h := shape.height * 0.5
    line_start := center + [3]f32{0, -h, 0}
    line_end := center + [3]f32{0, h, 0}
    closest := geometry.closest_point_on_segment(
      sphere_center,
      line_start,
      line_end,
    )
    len := shape.radius + sphere_radius
    return linalg.length2(closest - sphere_center) <= len * len
  case CylinderCollider:
    return test_point_cylinder(sphere_center, center, shape)
  case FanCollider:
    return test_point_fan(sphere_center, center, shape)
  }
  return false
}

// Test if collider overlaps with AABB
test_collider_aabb_overlap :: proc(
  collider: ^Collider,
  collider_pos: [3]f32,
  bounds: geometry.Aabb,
) -> bool {
  center := collider_pos + collider.offset
  // Use center point test for now - could be more precise
  return geometry.aabb_contains_point(bounds, center)
}
