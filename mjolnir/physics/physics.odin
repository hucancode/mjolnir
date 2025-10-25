package physics

import "core:slice"
import "../geometry"
import "../resources"
import "../world"

PhysicsWorld :: struct {
	bodies:        resources.Pool(RigidBody),
	colliders:     resources.Pool(Collider),
	contacts:      [dynamic]Contact,
	gravity:       [3]f32,
	iterations:    i32,
	spatial_index: geometry.BVH(resources.Handle),
}

BroadPhaseEntry :: struct {
	handle: resources.Handle,
	bounds: geometry.Aabb,
}

physics_world_init :: proc(world: ^PhysicsWorld, gravity := [3]f32{0, -9.81, 0}) {
	resources.pool_init(&world.bodies)
	resources.pool_init(&world.colliders)
	world.contacts = make([dynamic]Contact)
	world.gravity = gravity
	world.iterations = 4
	world.spatial_index = geometry.bvh_create(
		resources.Handle,
		proc(h: resources.Handle) -> geometry.Aabb {
			return {}
		},
	)
}

physics_world_destroy :: proc(world: ^PhysicsWorld) {
	resources.pool_destroy(&world.bodies)
	resources.pool_destroy(&world.colliders)
	delete(world.contacts)
	geometry.bvh_destroy(&world.spatial_index)
}

physics_world_create_body :: proc(
	world: ^PhysicsWorld,
	node_handle: resources.Handle,
	mass: f32,
	is_static := false,
) -> (
	resources.Handle,
	^RigidBody,
	bool,
) {
	handle, body, ok := resources.pool_alloc(&world.bodies)
	if !ok {
		return {}, nil, false
	}
	body^ = rigid_body_create(node_handle, mass, is_static)
	return handle, body, true
}

physics_world_destroy_body :: proc(world: ^PhysicsWorld, handle: resources.Handle) {
	body := resources.pool_get(&world.bodies, handle)
	if body != nil && body.collider_handle.index != 0 {
		resources.pool_free(&world.colliders, body.collider_handle)
	}
	resources.pool_free(&world.bodies, handle)
}

physics_world_add_collider :: proc(
	world: ^PhysicsWorld,
	body_handle: resources.Handle,
	collider: Collider,
) -> (
	resources.Handle,
	^Collider,
	bool,
) {
	body := resources.pool_get(&world.bodies, body_handle)
	if body == nil {
		return {}, nil, false
	}
	handle, col_ptr, ok := resources.pool_alloc(&world.colliders)
	if !ok {
		return {}, nil, false
	}
	col_ptr^ = collider
	body.collider_handle = handle
	return handle, col_ptr, true
}

physics_world_step :: proc(physics: ^PhysicsWorld, w: ^world.World, dt: f32) {
	clear(&physics.contacts)
	for entry in physics.bodies.entries {
		if !resources.is_alive(entry) {
			continue
		}
		body := &entry.value
		if !body.is_static && !body.is_kinematic {
			gravity_force := physics.gravity * body.mass * body.gravity_scale
			rigid_body_apply_force(body, gravity_force)
		}
	}
	for entry in physics.bodies.entries {
		if !resources.is_alive(entry) {
			continue
		}
		body := &entry.value
		rigid_body_integrate(body, dt)
	}
	broad_phase_entries := make([dynamic]BroadPhaseEntry, context.temp_allocator)
	for entry in physics.bodies.entries {
		if !resources.is_alive(entry) {
			continue
		}
		body := &entry.value
		if body.collider_handle.index == 0 {
			continue
		}
		node := resources.pool_get(&w.nodes, body.node_handle)
		if node == nil {
			continue
		}
		collider := resources.pool_get(&physics.colliders, body.collider_handle)
		if collider == nil {
			continue
		}
		pos := node.transform.position
		bounds := collider_get_aabb(collider, pos)
		append(&broad_phase_entries, BroadPhaseEntry{handle = entry.handle, bounds = bounds})
	}
	for i in 0 ..< len(broad_phase_entries) {
		for j in i + 1 ..< len(broad_phase_entries) {
			entry_a := broad_phase_entries[i]
			entry_b := broad_phase_entries[j]
			if !geometry.aabb_intersects(entry_a.bounds, entry_b.bounds) {
				continue
			}
			body_a := resources.pool_get(&physics.bodies, entry_a.handle)
			body_b := resources.pool_get(&physics.bodies, entry_b.handle)
			if body_a == nil || body_b == nil {
				continue
			}
			if body_a.is_static && body_b.is_static {
				continue
			}
			if body_a.collider_handle.index == 0 || body_b.collider_handle.index == 0 {
				continue
			}
			node_a := resources.pool_get(&w.nodes, body_a.node_handle)
			node_b := resources.pool_get(&w.nodes, body_b.node_handle)
			if node_a == nil || node_b == nil {
				continue
			}
			collider_a := resources.pool_get(&physics.colliders, body_a.collider_handle)
			collider_b := resources.pool_get(&physics.colliders, body_b.collider_handle)
			if collider_a == nil || collider_b == nil {
				continue
			}
			pos_a := node_a.transform.position
			pos_b := node_b.transform.position
			hit, point, normal, penetration := test_collision(
				collider_a,
				pos_a,
				collider_b,
				pos_b,
			)
			if hit {
				contact := Contact {
					body_a      = entry_a.handle,
					body_b      = entry_b.handle,
					point       = point,
					normal      = normal,
					penetration = penetration,
					restitution = (body_a.restitution + body_b.restitution) * 0.5,
					friction    = (body_a.friction + body_b.friction) * 0.5,
				}
				append(&physics.contacts, contact)
			}
		}
	}
	for _ in 0 ..< physics.iterations {
		for &contact in physics.contacts {
			body_a := resources.pool_get(&physics.bodies, contact.body_a)
			body_b := resources.pool_get(&physics.bodies, contact.body_b)
			if body_a == nil || body_b == nil {
				continue
			}
			node_a := resources.pool_get(&w.nodes, body_a.node_handle)
			node_b := resources.pool_get(&w.nodes, body_b.node_handle)
			if node_a == nil || node_b == nil {
				continue
			}
			pos_a := node_a.transform.position
			pos_b := node_b.transform.position
			resolve_contact(&contact, body_a, body_b, pos_a, pos_b)
		}
	}
	for entry in physics.bodies.entries {
		if !resources.is_alive(entry) {
			continue
		}
		body := &entry.value
		if body.is_static || body.is_kinematic {
			continue
		}
		node := resources.pool_get(&w.nodes, body.node_handle)
		if node == nil {
			continue
		}
		geometry.transform_translate_by(&node.transform, body.velocity * dt)
	}
}
