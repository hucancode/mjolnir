package physics

import "core:log"
import "core:slice"
import "../geometry"
import "../resources"
import "../world"

KILL_Y :: -50.0

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
	world.iterations = 8
	world.spatial_index = geometry.BVH(resources.Handle) {
		nodes      = make([dynamic]geometry.BVHNode),
		primitives = make([dynamic]resources.Handle),
		bounds_func = proc(h: resources.Handle) -> geometry.Aabb {
			return {}
		},
	}
}

physics_world_destroy :: proc(world: ^PhysicsWorld) {
	resources.pool_destroy(world.bodies, proc(body: ^RigidBody) {})
	resources.pool_destroy(world.colliders, proc(col: ^Collider) {})
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
	handle, body, ok := resources.alloc(&world.bodies)
	if !ok {
		return {}, nil, false
	}
	body^ = rigid_body_create(node_handle, mass, is_static)
	return handle, body, true
}

physics_world_destroy_body :: proc(world: ^PhysicsWorld, handle: resources.Handle) {
	body, _ := resources.get(world.bodies, handle)
	if body != nil && body.collider_handle.generation != 0 {
		resources.free(&world.colliders, body.collider_handle)
	}
	resources.free(&world.bodies, handle)
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
	body, body_ok := resources.get(world.bodies, body_handle)
	if !body_ok {
		return {}, nil, false
	}
	handle, col_ptr, ok := resources.alloc(&world.colliders)
	if !ok {
		return {}, nil, false
	}
	col_ptr^ = collider
	body.collider_handle = handle
	return handle, col_ptr, true
}

physics_world_step :: proc(physics: ^PhysicsWorld, w: ^world.World, dt: f32) {
	clear(&physics.contacts)
	for &entry in physics.bodies.entries {
		if !entry.active {
			continue
		}
		body := &entry.item
		if !body.is_static && !body.is_kinematic {
			gravity_force := physics.gravity * body.mass * body.gravity_scale
			rigid_body_apply_force(body, gravity_force)
		}
	}
	for &entry in physics.bodies.entries {
		if !entry.active {
			continue
		}
		body := &entry.item
		rigid_body_integrate(body, dt)
	}
	broad_phase_entries := make([dynamic]BroadPhaseEntry, context.temp_allocator)
	for &entry, idx in physics.bodies.entries {
		if !entry.active {
			continue
		}
		body := &entry.item
		if body.collider_handle.generation == 0 {
			continue
		}
		node, node_ok := resources.get(w.nodes, body.node_handle)
		if !node_ok {
			continue
		}
		collider, col_ok := resources.get(physics.colliders, body.collider_handle)
		if !col_ok {
			continue
		}
		pos := node.transform.position
		bounds := collider_get_aabb(collider, pos)
		handle := resources.Handle{index = u32(idx), generation = entry.generation}
		append(&broad_phase_entries, BroadPhaseEntry{handle = handle, bounds = bounds})
	}
	for i in 0 ..< len(broad_phase_entries) {
		for j in i + 1 ..< len(broad_phase_entries) {
			entry_a := broad_phase_entries[i]
			entry_b := broad_phase_entries[j]
			if !geometry.aabb_intersects(entry_a.bounds, entry_b.bounds) {
				continue
			}
			body_a, body_a_ok := resources.get(physics.bodies, entry_a.handle)
			body_b, body_b_ok := resources.get(physics.bodies, entry_b.handle)
			if !body_a_ok || !body_b_ok {
				continue
			}
			if body_a.is_static && body_b.is_static {
				continue
			}
			if body_a.collider_handle.generation == 0 || body_b.collider_handle.generation == 0 {
				continue
			}
			node_a, node_a_ok := resources.get(w.nodes, body_a.node_handle)
			node_b, node_b_ok := resources.get(w.nodes, body_b.node_handle)
			if !node_a_ok || !node_b_ok {
				continue
			}
			collider_a, col_a_ok := resources.get(physics.colliders, body_a.collider_handle)
			collider_b, col_b_ok := resources.get(physics.colliders, body_b.collider_handle)
			if !col_a_ok || !col_b_ok {
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
			body_a, body_a_ok := resources.get(physics.bodies, contact.body_a)
			body_b, body_b_ok := resources.get(physics.bodies, contact.body_b)
			if !body_a_ok || !body_b_ok {
				continue
			}
			node_a, node_a_ok := resources.get(w.nodes, body_a.node_handle)
			node_b, node_b_ok := resources.get(w.nodes, body_b.node_handle)
			if !node_a_ok || !node_b_ok {
				continue
			}
			pos_a := node_a.transform.position
			pos_b := node_b.transform.position
			resolve_contact(&contact, body_a, body_b, pos_a, pos_b)
		}
	}
	for &entry in physics.bodies.entries {
		if !entry.active {
			continue
		}
		body := &entry.item
		if body.is_static || body.is_kinematic {
			continue
		}
		node, node_ok := resources.get(w.nodes, body.node_handle)
		if !node_ok {
			continue
		}
		vel := body.velocity * dt
		geometry.transform_translate_by(&node.transform, vel.x, vel.y, vel.z)
	}

	// Kill bodies that fall below kill_y threshold
	bodies_to_kill := make([dynamic]resources.Handle, context.temp_allocator)
	for &entry, idx in physics.bodies.entries {
		if !entry.active {
			continue
		}
		body := &entry.item
		if body.is_static || body.is_kinematic {
			continue
		}
		node, node_ok := resources.get(w.nodes, body.node_handle)
		if !node_ok {
			continue
		}
		if node.transform.position.y < KILL_Y {
			handle := resources.Handle{index = u32(idx), generation = entry.generation}
			append(&bodies_to_kill, handle)
		}
	}

	// Remove killed bodies
	for handle in bodies_to_kill {
		body, body_ok := resources.get(physics.bodies, handle)
		if body_ok {
			node, _ := resources.get(w.nodes, body.node_handle)
			log.infof("Removing body at y=%.2f (below KILL_Y=%.2f)",
				node.transform.position.y, KILL_Y)
		}
		physics_world_destroy_body(physics, handle)
	}
}
