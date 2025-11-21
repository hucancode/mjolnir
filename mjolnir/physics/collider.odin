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
  type:   ColliderType,
  offset: [3]f32,
  shape:  ColliderShape,
}

ColliderShape :: union {
  SphereCollider,
  BoxCollider,
  CapsuleCollider,
  CylinderCollider,
  FanCollider,
}

collider_create_sphere :: proc(radius: f32, offset: [3]f32 = {}) -> Collider {
  return Collider {
    type = .Sphere,
    offset = offset,
    shape = SphereCollider{radius = radius},
  }
}

collider_create_box :: proc(
  half_extents: [3]f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> Collider {
  return Collider {
    type = .Box,
    offset = offset,
    shape = BoxCollider{half_extents = half_extents, rotation = rotation},
  }
}

collider_create_capsule :: proc(
  radius: f32,
  height: f32,
  offset: [3]f32 = {},
) -> Collider {
  return Collider {
    type = .Capsule,
    offset = offset,
    shape = CapsuleCollider{radius = radius, height = height},
  }
}

collider_create_cylinder :: proc(
  radius: f32,
  height: f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> Collider {
  return Collider {
    type = .Cylinder,
    offset = offset,
    shape = CylinderCollider{radius = radius, height = height, rotation = rotation},
  }
}

collider_create_fan :: proc(
  radius: f32,
  height: f32,
  angle: f32,
  offset: [3]f32 = {},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> Collider {
  return Collider {
    type = .Fan,
    offset = offset,
    shape = FanCollider{radius = radius, height = height, angle = angle, rotation = rotation},
  }
}

collider_get_aabb :: proc(
  collider: ^Collider,
  position: [3]f32,
) -> geometry.Aabb {
  center := position + collider.offset
  switch collider.type {
  case .Sphere:
    sphere := collider.shape.(SphereCollider)
    r := [3]f32{sphere.radius, sphere.radius, sphere.radius}
    return geometry.Aabb{min = center - r, max = center + r}
  case .Box:
    box := collider.shape.(BoxCollider)
    obb := geometry.Obb {
      center       = center,
      half_extents = box.half_extents,
      rotation     = box.rotation,
    }
    return geometry.obb_to_aabb(obb)
  case .Capsule:
    capsule := collider.shape.(CapsuleCollider)
    r := capsule.radius
    h := capsule.height * 0.5
    extents := [3]f32{r, h + r, r}
    return geometry.Aabb{min = center - extents, max = center + extents}
  case .Cylinder:
    cylinder := collider.shape.(CylinderCollider)
    r := cylinder.radius
    h := cylinder.height * 0.5
    // Conservative AABB for rotated cylinder
    half_extents := [3]f32{r, h, r}
    obb := geometry.Obb {
      center       = center,
      half_extents = half_extents,
      rotation     = cylinder.rotation,
    }
    return geometry.obb_to_aabb(obb)
  case .Fan:
    fan := collider.shape.(FanCollider)
    r := fan.radius
    h := fan.height * 0.5
    // Conservative AABB for fan (treat as full cylinder)
    half_extents := [3]f32{r, h, r}
    obb := geometry.Obb {
      center       = center,
      half_extents = half_extents,
      rotation     = fan.rotation,
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
