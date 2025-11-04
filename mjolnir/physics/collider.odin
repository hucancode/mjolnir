package physics

import "../geometry"
import "core:math/linalg"

ColliderType :: enum {
  Sphere,
  Box,
  Capsule,
}

SphereCollider :: struct {
  radius: f32,
}

BoxCollider :: struct {
  half_extents: [3]f32,
  rotation:     quaternion128, // Orientation of the box
}

// Initialize a box collider with given half-extents and rotation
box_collider_init :: proc(half_extents: [3]f32, rotation := linalg.QUATERNIONF32_IDENTITY) -> BoxCollider {
  return BoxCollider {
    half_extents = half_extents,
    rotation = rotation,
  }
}

CapsuleCollider :: struct {
  radius: f32,
  height: f32,
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
}

collider_create_sphere :: proc(radius: f32, offset := [3]f32{}) -> Collider {
  return Collider {
    type = .Sphere,
    offset = offset,
    shape = SphereCollider{radius = radius},
  }
}

collider_create_box :: proc(
  half_extents: [3]f32,
  offset := [3]f32{},
  rotation := linalg.QUATERNIONF32_IDENTITY,
) -> Collider {
  return Collider {
    type = .Box,
    offset = offset,
    shape = box_collider_init(half_extents, rotation),
  }
}

collider_create_capsule :: proc(
  radius: f32,
  height: f32,
  offset := [3]f32{},
) -> Collider {
  return Collider {
    type = .Capsule,
    offset = offset,
    shape = CapsuleCollider{radius = radius, height = height},
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
    // For oriented boxes, compute AABB that contains all 8 corners
    corners := [8][3]f32 {
      {-box.half_extents.x, -box.half_extents.y, -box.half_extents.z},
      {box.half_extents.x, -box.half_extents.y, -box.half_extents.z},
      {-box.half_extents.x, box.half_extents.y, -box.half_extents.z},
      {box.half_extents.x, box.half_extents.y, -box.half_extents.z},
      {-box.half_extents.x, -box.half_extents.y, box.half_extents.z},
      {box.half_extents.x, -box.half_extents.y, box.half_extents.z},
      {-box.half_extents.x, box.half_extents.y, box.half_extents.z},
      {box.half_extents.x, box.half_extents.y, box.half_extents.z},
    }
    aabb := geometry.AABB_UNDEFINED
    for corner in corners {
      rotated := linalg.quaternion128_mul_vector3(box.rotation, corner)
      world_corner := center + rotated
      aabb.min = linalg.min(aabb.min, world_corner)
      aabb.max = linalg.max(aabb.max, world_corner)
    }
    return aabb
  case .Capsule:
    capsule := collider.shape.(CapsuleCollider)
    r := capsule.radius
    h := capsule.height * 0.5
    extents := [3]f32{r, h + r, r}
    return geometry.Aabb{min = center - extents, max = center + extents}
  }
  return {}
}
