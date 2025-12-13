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

CapsuleCollider :: struct {
  radius: f32,
  height: f32,
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
  offset:               [3]f32,
  cross_sectional_area: f32,
  shape:                union {
    SphereCollider,
    BoxCollider,
    CapsuleCollider,
    CylinderCollider,
    FanCollider,
  },
}

collider_calculate_aabb :: proc(
  self: ^Collider,
  position: [3]f32,
  rotation: quaternion128,
) -> geometry.Aabb {
  center := position + linalg.mul(rotation, self.offset)
  switch sh in self.shape {
  case SphereCollider:
    return geometry.Aabb{min = center - sh.radius, max = center + sh.radius}
  case BoxCollider:
    obb := geometry.Obb {
      center       = center,
      half_extents = sh.half_extents,
      rotation     = rotation,
    }
    return geometry.obb_to_aabb(obb)
  case CapsuleCollider:
    r := sh.radius
    h := sh.height * 0.5
    extents := [3]f32{r, h + r, r}
    return geometry.Aabb{min = center - extents, max = center + extents}
  case CylinderCollider:
    r := sh.radius
    h := sh.height * 0.5
    // Conservative AABB for rotated cylinder
    half_extents := [3]f32{r, h, r}
    obb := geometry.Obb {
      center       = center,
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
      center       = center,
      half_extents = half_extents,
      rotation     = rotation,
    }
    return geometry.obb_to_aabb(obb)
  }
  return {}
}
