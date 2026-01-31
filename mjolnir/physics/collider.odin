package physics

import "../geometry"
import "core:math"
import "core:math/linalg"

ColliderType :: enum {
  Sphere,
  Box,
  Capsule,
  Cylinder,
  Fan,
}

SphereCollider :: struct {
  radius: f32,
}

BoxCollider :: struct {
  half_extents: [3]f32,
}

CylinderCollider :: struct {
  radius: f32,
  height: f32,
}

FanCollider :: struct {
  radius: f32,
  height: f32,
  angle:  f32, // radians - total angle of the fan sector
}

Collider :: struct {
  cross_sectional_area: f32,
  shape:                union {
    SphereCollider,
    BoxCollider,
    CylinderCollider,
    FanCollider,
  },
}

collider_calculate_aabb :: #force_inline proc(
  self: ^Collider,
  position: [3]f32,
  rotation: quaternion128,
) -> geometry.Aabb {
  switch sh in self.shape {
  case SphereCollider:
    return geometry.Aabb{min = position - sh.radius, max = position + sh.radius}
  case BoxCollider:
    obb := geometry.Obb {
      center       = position,
      half_extents = sh.half_extents,
      rotation     = rotation,
    }
    return geometry.obb_to_aabb(obb)
  case CylinderCollider:
    r := sh.radius
    h := sh.height * 0.5
    // Conservative AABB for rotated cylinder
    half_extents := [3]f32{r, h, r}
    obb := geometry.Obb {
      center       = position,
      half_extents = half_extents,
      rotation     = rotation,
    }
    return geometry.obb_to_aabb(obb)
  case FanCollider:
    r := sh.radius
    h := sh.height * 0.5
    // Conservative AABB for fan (treat as full cylinder)
    half_extents := [3]f32{r, h, r}
    obb := geometry.Obb {
      center       = position,
      half_extents = half_extents,
      rotation     = rotation,
    }
    return geometry.obb_to_aabb(obb)
  }
  return {}
}

collider_min_extent :: proc(self: ^Collider) -> f32 {
  switch sh in self.shape {
  case SphereCollider:
    return sh.radius * 2.0
  case BoxCollider:
    return min(sh.half_extents.x, sh.half_extents.y, sh.half_extents.z) * 2.0
  case CylinderCollider:
    return min(sh.radius, sh.height * 0.5) * 2.0
  case FanCollider:
    return min(sh.radius, sh.height * 0.5) * 2.0
  }
  return 1.0
}
