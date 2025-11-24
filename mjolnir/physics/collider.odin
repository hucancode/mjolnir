package physics

import "../geometry"
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
  rotation:     quaternion128,
}

CapsuleCollider :: struct {
  radius: f32,
  height: f32,
}

CylinderCollider :: struct {
  radius:   f32,
  height:   f32,
  rotation: quaternion128,
}

FanCollider :: struct {
  radius:   f32,
  height:   f32,
  angle:    f32, // radians - total angle of the fan sector
  rotation: quaternion128, // orientation - forward direction is center of fan
}

Collider :: struct {
  offset: [3]f32,
  shape:  union {
    SphereCollider,
    BoxCollider,
    CapsuleCollider,
    CylinderCollider,
    FanCollider,
  },
}

collider_sphere :: proc(radius: f32 = 1.0, offset: [3]f32 = {}) -> Collider {
  return Collider{offset = offset, shape = SphereCollider{radius = radius}}
}

collider_box :: proc(
  half_extents: [3]f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> Collider {
  return Collider {
    offset = offset,
    shape = BoxCollider{half_extents = half_extents, rotation = rotation},
  }
}

collider_capsule :: proc(
  radius: f32,
  height: f32,
  offset: [3]f32 = {},
) -> Collider {
  return Collider {
    offset = offset,
    shape = CapsuleCollider{radius = radius, height = height},
  }
}

collider_cylinder :: proc(
  radius: f32,
  height: f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> Collider {
  return Collider {
    offset = offset,
    shape = CylinderCollider {
      radius = radius,
      height = height,
      rotation = rotation,
    },
  }
}

collider_fan :: proc(
  radius: f32,
  height: f32,
  angle: f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> Collider {
  return Collider {
    offset = offset,
    shape = FanCollider {
      radius = radius,
      height = height,
      angle = angle,
      rotation = rotation,
    },
  }
}

collider_get_aabb :: proc(self: ^Collider, position: [3]f32) -> geometry.Aabb {
  center := position + self.offset
  switch sh in self.shape {
  case SphereCollider:
    r := [3]f32{sh.radius, sh.radius, sh.radius}
    return geometry.Aabb{min = center - r, max = center + r}
  case BoxCollider:
    obb := geometry.Obb {
      center       = center,
      half_extents = sh.half_extents,
      rotation     = sh.rotation,
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
      rotation     = sh.rotation,
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
      rotation     = sh.rotation,
    }
    return geometry.obb_to_aabb(obb)
  }
  return {}
}

// Get OBB for a box collider
collider_get_obb :: proc(
  collider: ^Collider,
  position: [3]f32,
) -> geometry.Obb {
  center := position + collider.offset
  box := collider.shape.(BoxCollider)
  return geometry.Obb {
    center = center,
    half_extents = box.half_extents,
    rotation = box.rotation,
  }
}
