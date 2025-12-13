package main

import "../../../mjolnir"
import cont "../../../mjolnir/containers"
import "../../../mjolnir/geometry"
import "../../../mjolnir/physics"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"

physics_world: physics.World
cube_handle: resources.NodeHandle
ground_handle: resources.NodeHandle
cube_body: physics.DynamicRigidBodyHandle
ground_body: physics.DynamicRigidBodyHandle
time_since_jump: f32

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
  using mjolnir
  physics.init(&physics_world, {0, -10, 0})
  ground_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
  ground_body := physics.create_body_box(
    &physics_world,
    half_extents = {40.0, 0.5, 40.0},
    is_static = true,
  )
  ground_handle = spawn(
    engine,
    [3]f32{0, -0.5, 0},
    world.RigidBodyAttachment{body_handle = ground_body},
  )
  ground_mesh_handle := spawn_child(
    engine,
    ground_handle,
    attachment = world.MeshAttachment {
      handle = ground_mesh,
      material = ground_mat,
    },
  )
  world.scale_xyz(&engine.world, ground_mesh_handle, 40.0, 0.5, 40.0)
  log.info("Ground body created")
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  cube_mat := engine.rm.builtin_materials[resources.Color.CYAN]
  cube_body = physics.create_body_box(
    &physics_world,
    half_extents = {1.0, 1.0, 1.0},
    position = {0, 3, 0},
    mass = 2.0,
  )
  if body, ok := physics.get(&physics_world, cube_body); ok {
    physics.set_box_inertia(body, [3]f32{1.0, 1.0, 1.0})
  }
  cube_handle = spawn(
    engine,
    [3]f32{0, 3, 0},
    world.RigidBodyAttachment{body_handle = cube_body},
  )
  spawn_child(
    engine,
    cube_handle,
    attachment = world.MeshAttachment {
      handle = cube_mesh,
      material = cube_mat,
      cast_shadow = true,
    },
  )
  log.info("Cube body created")
  if camera := get_main_camera(engine); camera != nil {
    camera_look_at(camera, {8, 5, 8}, {0, 2, 0})
    sync_active_camera_controller(engine)
  }
  time_since_jump = 0.0
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
  cube_body, body_ok := cont.get(physics_world.bodies, cube_body)
  if !body_ok {
    return
  }
  switch key {
  case glfw.KEY_SPACE:
    time_since_jump = 0.0
    physics.apply_force(cube_body, [3]f32{0, JUMP_FORCE, 0})
  case glfw.KEY_1:
    physics.set_mass(cube_body, 5.0)
    physics.set_box_inertia(cube_body, [3]f32{1.0, 1.0, 1.0})
    log.info("Mass set to 5.0 kg (Light)")
  case glfw.KEY_2:
    physics.set_mass(cube_body, 20.0)
    physics.set_box_inertia(cube_body, [3]f32{1.0, 1.0, 1.0})
    log.info("Mass set to 20.0 kg (Medium)")
  case glfw.KEY_3:
    physics.set_mass(cube_body, 50.0)
    physics.set_box_inertia(cube_body, [3]f32{1.0, 1.0, 1.0})
    log.info("Mass set to 50.0 kg (Heavy)")
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  time_since_jump += delta_time
  cube_body, body_ok := cont.get(physics_world.bodies, cube_body)
  if !body_ok {
    return
  }
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
    physics.apply_force(cube_body, move_force)
  }
  if time_since_jump >= JUMP_INTERVAL {
    time_since_jump = 0.0
    physics.apply_force(cube_body, [3]f32{0, JUMP_FORCE, 0})
  }
  physics.step(&physics_world, delta_time)
  world.sync_all_physics_to_world(&engine.world, &physics_world)
}
