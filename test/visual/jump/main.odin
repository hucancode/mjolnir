package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "../../../mjolnir"
import cont "../../../mjolnir/containers"
import "../../../mjolnir/geometry"
import "../../../mjolnir/physics"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "vendor:glfw"

demo_state: struct {
	physics_world:   physics.PhysicsWorld,
	cube_handle:     resources.Handle,
	ground_handle:   resources.Handle,
	cube_body:       resources.Handle,
	ground_body:     resources.Handle,
	time_since_jump: f32,
}

JUMP_INTERVAL :: 5.0
JUMP_FORCE :: 1000.0
MOVEMENT_FORCE :: 20.0

main :: proc() {
	context.logger = log.create_console_logger()
	engine := new(mjolnir.Engine)
	engine.setup_proc = setup
	engine.update_proc = update
	engine.key_press_proc = on_key_press
	mjolnir.run(engine, 800, 600, "Physics Visual Test - Jumping Cube")
}

setup :: proc(engine: ^mjolnir.Engine) {
	using mjolnir, geometry
	log.info("Setting up jump demo")
	physics.init(&demo_state.physics_world, {0, -10, 0})
	ground_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
	ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
	h, ground_node_ptr, _ := spawn_at(
		engine,
		[3]f32{0, -0.5, 0},
		world.MeshAttachment{handle = ground_mesh, material = ground_mat},
	)
	demo_state.ground_handle = h
	if ground_node_ptr != nil {
		world.scale_xyz(ground_node_ptr, 40.0, 0.5, 40.0)
	}
	ground_node, ground_node_ok := cont.get(engine.world.nodes, demo_state.ground_handle)
	if ground_node_ok {
		body_handle, body, ok := physics.create_body(
			&demo_state.physics_world,
			demo_state.ground_handle,
			0.0,
			true,
		)
		if ok {
			demo_state.ground_body = body_handle
			collider := physics.collider_create_box([3]f32{40.0, 0.5, 40.0})
			physics.add_collider(&demo_state.physics_world, body_handle, collider)
			log.info("Ground body created")
		}
	}
	cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
	cube_mat := engine.rm.builtin_materials[resources.Color.CYAN]
	demo_state.cube_handle, _, _ = spawn_at(
		engine,
		[3]f32{0, 3, 0},
		world.MeshAttachment{handle = cube_mesh, material = cube_mat, cast_shadow = true},
	)
	cube_node, cube_node_ok := cont.get(engine.world.nodes, demo_state.cube_handle)
	if cube_node_ok {
		body_handle, body, ok := physics.create_body(
			&demo_state.physics_world,
			demo_state.cube_handle,
			2.0,
			false,
		)
		if ok {
			demo_state.cube_body = body_handle
			collider := physics.collider_create_box([3]f32{1.0, 1.0, 1.0})
			physics.add_collider(&demo_state.physics_world, body_handle, collider)
			physics.rigid_body_set_box_inertia(body, [3]f32{1.0, 1.0, 1.0})
			log.info("Cube body created")
		}
	}
	camera := get_main_camera(engine)
	if camera != nil {
		resources.camera_look_at(camera, {8, 5, 8}, {0, 2, 0})
	}
	demo_state.time_since_jump = 0.0
	log.info("====================================")
	log.info("CONTROLS:")
	log.info("  SPACE - Jump")
	log.info("  W/A/S/D - Move horizontally")
	log.info("  1 - Set mass to 5 kg (Light)")
	log.info("  2 - Set mass to 20 kg (Medium)")
	log.info("  3 - Set mass to 50 kg (Heavy)")
	log.info("====================================")
}

on_key_press :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
	// Only handle key press events, not release or repeat
	if action != glfw.PRESS {
		return
	}
	cube_body, body_ok := cont.get(
		demo_state.physics_world.bodies,
		demo_state.cube_body,
	)
	if !body_ok {
		return
	}

	switch key {
	case glfw.KEY_SPACE:
		demo_state.time_since_jump = 0.0
		apply_jump(engine)
	case glfw.KEY_1:
		physics.rigid_body_set_mass(cube_body, 5.0)
		physics.rigid_body_set_box_inertia(cube_body, [3]f32{1.0, 1.0, 1.0})
		log.info("Mass set to 5.0 kg (Light)")
	case glfw.KEY_2:
		physics.rigid_body_set_mass(cube_body, 20.0)
		physics.rigid_body_set_box_inertia(cube_body, [3]f32{1.0, 1.0, 1.0})
		log.info("Mass set to 20.0 kg (Medium)")
	case glfw.KEY_3:
		physics.rigid_body_set_mass(cube_body, 50.0)
		physics.rigid_body_set_box_inertia(cube_body, [3]f32{1.0, 1.0, 1.0})
		log.info("Mass set to 50.0 kg (Heavy)")
	}
}

apply_jump :: proc(engine: ^mjolnir.Engine) {
	cube_body, body_ok := cont.get(
		demo_state.physics_world.bodies,
		demo_state.cube_body,
	)
	if !body_ok do return
	jump_force := [3]f32{0, JUMP_FORCE, 0}
	physics.rigid_body_apply_force(cube_body, jump_force)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
	demo_state.time_since_jump += delta_time
	cube_body, body_ok := cont.get(
		demo_state.physics_world.bodies,
		demo_state.cube_body,
	)
	if body_ok {
		// Horizontal movement controls (WASD) - continuous polling for smooth movement
		move_force := [3]f32{0, 0, 0}
		if glfw.GetKey(engine.window, glfw.KEY_W) == glfw.PRESS {
			move_force.z -= MOVEMENT_FORCE
		}
		if glfw.GetKey(engine.window, glfw.KEY_S) == glfw.PRESS {
			move_force.z += MOVEMENT_FORCE
		}
		if glfw.GetKey(engine.window, glfw.KEY_A) == glfw.PRESS {
			move_force.x -= MOVEMENT_FORCE
		}
		if glfw.GetKey(engine.window, glfw.KEY_D) == glfw.PRESS {
			move_force.x += MOVEMENT_FORCE
		}
		if linalg.length(move_force) > 0.1 {
			physics.rigid_body_apply_force(cube_body, move_force)
		}
	}
	if demo_state.time_since_jump >= JUMP_INTERVAL {
		demo_state.time_since_jump = 0.0
		apply_jump(engine)
	}
	physics.step(&demo_state.physics_world, &engine.world, delta_time)
}
