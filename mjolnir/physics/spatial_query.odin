package physics

import "../geometry"
import "core:math"
import "core:math/linalg"

// RayHit is a raycast result; hit is false when nothing was hit.
RayHit :: struct {
  body:   BodyHandle,
  t:      f32,
  point:  [3]f32,
  normal: [3]f32,
  hit:    bool,
}

// Test ray against one BVH's candidates, tightening `closest` in place.
// first_hit stops at the first intersection (any-hit query).
// Returns true if a hit was recorded.
@(private = "file")
raycast_candidates :: proc(
  self: ^World,
  candidates: []BroadPhaseEntry,
  ray: geometry.Ray,
  closest: ^RayHit,
  first_hit: bool,
) -> (found: bool) {
  for candidate in candidates {
    body := lookup(self, candidate.handle) or_continue
    t, normal, hit := raycast_collider(ray, &body.collider, body.position, body.rotation, closest.t)
    if hit && t < closest.t {
      closest^ = {
        body   = candidate.handle,
        t      = t,
        point  = ray.origin + ray.direction * t,
        normal = normal,
        hit    = true,
      }
      found = true
      if first_hit do return
    }
  }
  return
}

// raycast returns the closest body hit by the ray; first_hit = true returns the first hit found
// instead (early exit). Sensors are not hit.
raycast :: proc(
  self: ^World,
  ray: geometry.Ray,
  max_dist: f32 = max(f32),
  first_hit := false,
) -> RayHit {
  refresh_broadphase(self)
  closest := RayHit{t = max_dist}
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  for bvh in ([2]^geometry.BVH(BroadPhaseEntry){&self.dynamic_bvh, &self.static_bvh}) {
    clear(&candidates)
    geometry.bvh_query_ray(bvh, ray, max_dist, &candidates)
    if raycast_candidates(self, candidates[:], ray, &closest, first_hit) && first_hit do break
  }
  return closest
}

// overlap collects the bodies whose collider overlaps `collider` placed at position/rotation.
// Sensors are not reported. Appends to `results` after clearing it.
overlap :: proc(
  self: ^World,
  collider: Collider,
  position: [3]f32,
  rotation: quaternion128,
  results: ^[dynamic]BodyHandle,
) {
  clear(results)
  refresh_broadphase(self)
  shape := collider
  bounds := collider_calculate_aabb(&shape, position, rotation)
  candidates := make([dynamic]BroadPhaseEntry, context.temp_allocator)
  for bvh in ([2]^geometry.BVH(BroadPhaseEntry){&self.dynamic_bvh, &self.static_bvh}) {
    clear(&candidates)
    geometry.bvh_query_aabb(bvh, bounds, &candidates)
    for candidate in candidates {
      body := lookup(self, candidate.handle) or_continue
      if _, hit := collide(&shape, position, rotation, &body.collider, body.position, body.rotation); hit {
        append(results, candidate.handle)
      }
    }
  }
}

// Raycast against a specific collider. The ray is tested in the collider's
// local frame (Y = cylinder axis) and the hit normal
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
    t, local_normal, hit = raycast_local_cylinder(local, shape.radius, shape.height)
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

// Ray vs a cylinder centered on the origin with axis Y. Takes the nearest
// hit among the caps and the curved wall, each clipped to the solid.
@(private = "file")
raycast_local_cylinder :: proc(
  ray: geometry.Ray,
  radius, height: f32,
) -> (
  t: f32,
  normal: [3]f32,
  hit: bool,
) {
  half_h := height * 0.5
  r2 := radius * radius
  if linalg.length2(ray.origin.xz) <= r2 && math.abs(ray.origin.y) <= half_h {
    return 0, -linalg.normalize(ray.direction), true
  }
  t = max(f32)
  if math.abs(ray.direction.y) > 1e-8 {
    for side in ([2]f32{-1, 1}) {
      s := (side * half_h - ray.origin.y) / ray.direction.y
      p := ray.origin + ray.direction * s
      if s >= 0 && s < t && linalg.length2(p.xz) <= r2 {
        t, normal, hit = s, {0, side, 0}, true
      }
    }
  }
  // Curved wall: |o.xz + s*d.xz|^2 = r^2, entering root
  a := linalg.length2(ray.direction.xz)
  if a > 1e-12 {
    b := linalg.dot(ray.origin.xz, ray.direction.xz)
    c := linalg.length2(ray.origin.xz) - r2
    disc := b * b - a * c
    if disc >= 0 {
      s := (-b - math.sqrt(disc)) / a
      p := ray.origin + ray.direction * s
      if s >= 0 && s < t && math.abs(p.y) <= half_h {
        t, normal, hit = s, {p.x / radius, 0, p.z / radius}, true
      }
    }
  }
  if !hit do t = 0
  return
}
