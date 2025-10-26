package physics

import "../geometry"

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
	return Collider{type = .Sphere, offset = offset, shape = SphereCollider{radius = radius}}
}

collider_create_box :: proc(half_extents: [3]f32, offset := [3]f32{}) -> Collider {
	return Collider {
		type = .Box,
		offset = offset,
		shape = BoxCollider{half_extents = half_extents},
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

collider_get_aabb :: proc(collider: ^Collider, position: [3]f32) -> geometry.Aabb {
	center := position + collider.offset
	switch collider.type {
	case .Sphere:
		sphere := collider.shape.(SphereCollider)
		r := [3]f32{sphere.radius, sphere.radius, sphere.radius}
		return geometry.Aabb{min = center - r, max = center + r}
	case .Box:
		box := collider.shape.(BoxCollider)
		return geometry.Aabb{min = center - box.half_extents, max = center + box.half_extents}
	case .Capsule:
		capsule := collider.shape.(CapsuleCollider)
		r := capsule.radius
		h := capsule.height * 0.5
		extents := [3]f32{r, h + r, r}
		return geometry.Aabb{min = center - extents, max = center + extents}
	}
	return {}
}
