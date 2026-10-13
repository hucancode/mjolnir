package physics

import "../geometry"
import "core:math"
import "core:math/linalg"

// SphereCollider is a sphere of the given radius centered on the body.
SphereCollider :: struct {
  radius: f32,
}

// BoxCollider is a box given by its half extents in body space.
BoxCollider :: struct {
  half_extents: [3]f32,
}

// CylinderCollider is a cylinder whose axis is local Y.
CylinderCollider :: struct {
  radius: f32,
  height: f32,
}

// Collider is the shape of a Body: sphere, box or cylinder.
Collider :: union {
  SphereCollider,
  BoxCollider,
  CylinderCollider,
}

@(private)
collider_calculate_aabb :: proc(
  self: ^Collider,
  position: [3]f32,
  rotation: quaternion128,
) -> geometry.Aabb {
  half_extents: [3]f32
  switch sh in self {
  case SphereCollider:
    return geometry.Aabb{min = position - sh.radius, max = position + sh.radius}
  case BoxCollider:
    half_extents = sh.half_extents
  case CylinderCollider:
    // Conservative: the cylinder's bounding box
    half_extents = {sh.radius, sh.height * 0.5, sh.radius}
  case:
    return {}
  }
  return geometry.obb_to_aabb(geometry.Obb{center = position, half_extents = half_extents, rotation = rotation})
}

@(private)
collider_bounding_radius :: proc(self: ^Collider) -> f32 {
  switch sh in self {
  case SphereCollider:
    return sh.radius
  case BoxCollider:
    return linalg.length(sh.half_extents)
  case CylinderCollider:
    h := sh.height * 0.5
    return math.sqrt(sh.radius * sh.radius + h * h)
  }
  return 0
}

@(private)
collider_min_extent :: proc(self: ^Collider) -> f32 {
  switch sh in self {
  case SphereCollider:
    return sh.radius * 2.0
  case BoxCollider:
    return min(sh.half_extents.x, sh.half_extents.y, sh.half_extents.z) * 2.0
  case CylinderCollider:
    return min(sh.radius, sh.height * 0.5) * 2.0
  }
  return 1.0
}

// Diagonal body-space inverse inertia of the solid shape. A nil collider
// gets a unit-sphere-like {inv_mass, inv_mass, inv_mass}.
@(private)
collider_inv_inertia :: proc(self: ^Collider, inv_mass: f32) -> [3]f32 {
  switch sh in self {
  case SphereCollider:
    inv_i := 2.5 * inv_mass / (sh.radius * sh.radius)
    return {inv_i, inv_i, inv_i}
  case BoxCollider:
    v := sh.half_extents * sh.half_extents
    return 3.0 * inv_mass / [3]f32{v.y + v.z, v.x + v.z, v.x + v.y}
  case CylinderCollider:
    r2 := sh.radius * sh.radius
    inv_ix := 12.0 * inv_mass / (3.0 * r2 + sh.height * sh.height)
    return {inv_ix, 2.0 * inv_mass / r2, inv_ix}
  }
  return inv_mass
}
