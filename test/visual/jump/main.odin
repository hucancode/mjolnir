package main

import "../../../mjolnir"
import "../../../mjolnir/physics"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math/linalg"
import "vendor:glfw"

physics_world: physics.World
cube_handle: resources.NodeHandle
ground_handle: resources.NodeHandle
cube_body: physics.DynamicRigidBodyHandle
time_since_jump: f32

JUMP_INTERVAL :: 5.0
JUMP_FORCE :: 1000.0
MOVEMENT_FORCE :: 20.0

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Physics Visual Test - Jumping Cube")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  physics.init(&physics_world, {0, -10, 0})
  ground_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
  physics.create_static_body_box(
    &physics_world,
    {40.0, 0.5, 40.0},
    {0, -0.5, 0},
  )
  ground_handle = spawn(
    engine,
    [3]f32{0, -0.5, 0},
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
  cube_collider := physics.create_collider_box(
    &physics_world,
    {1.0, 1.0, 1.0},
  )
  cube_body := physics.create_dynamic_body(
    &physics_world,
    {0, 3, 0},
    linalg.QUATERNIONF32_IDENTITY,
    2.0,
    false,
    cube_collider,
  )
  if body, ok := physics.get_dynamic_body(&physics_world, cube_body); ok {
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

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  time_since_jump += delta_time
  cube_body_ptr, body_ok := physics.get_dynamic_body(
    &physics_world,
    cube_body,
  )
  if !body_ok {
    return
  }
  // Input is sampled in update_input on the main thread; use the cached state
  space_pressed := engine.input.keys[glfw.KEY_SPACE] &&
                   !engine.input.key_holding[glfw.KEY_SPACE]
  mass_light_pressed := engine.input.keys[glfw.KEY_1] &&
                        !engine.input.key_holding[glfw.KEY_1]
  mass_medium_pressed := engine.input.keys[glfw.KEY_2] &&
                         !engine.input.key_holding[glfw.KEY_2]
  mass_heavy_pressed := engine.input.keys[glfw.KEY_3] &&
                        !engine.input.key_holding[glfw.KEY_3]
  // Horizontal movement controls (WASD) - continuous polling for smooth movement
  move_force := [3]f32{0, 0, 0}
  if engine.input.keys[glfw.KEY_W] {
    move_force.z -= MOVEMENT_FORCE
  }
  if engine.input.keys[glfw.KEY_S] {
    move_force.z += MOVEMENT_FORCE
  }
  if engine.input.keys[glfw.KEY_A] {
    move_force.x -= MOVEMENT_FORCE
  }
  if engine.input.keys[glfw.KEY_D] {
    move_force.x += MOVEMENT_FORCE
  }
  if linalg.length(move_force) > 0.1 {
    physics.apply_force(cube_body_ptr, move_force)
  }
  if mass_light_pressed {
    physics.set_mass(cube_body_ptr, 5.0)
    physics.set_box_inertia(cube_body_ptr, [3]f32{1.0, 1.0, 1.0})
    log.info("Mass set to 5.0 kg (Light)")
  }
  if mass_medium_pressed {
    physics.set_mass(cube_body_ptr, 20.0)
    physics.set_box_inertia(cube_body_ptr, [3]f32{1.0, 1.0, 1.0})
    log.info("Mass set to 20.0 kg (Medium)")
  }
  if mass_heavy_pressed {
    physics.set_mass(cube_body_ptr, 50.0)
    physics.set_box_inertia(cube_body_ptr, [3]f32{1.0, 1.0, 1.0})
    log.info("Mass set to 50.0 kg (Heavy)")
  }
  if space_pressed || time_since_jump >= JUMP_INTERVAL {
    time_since_jump = 0.0
    physics.apply_force(cube_body_ptr, [3]f32{0, JUMP_FORCE, 0})
  }
  physics.step(&physics_world, delta_time)
  world.sync_all_physics_to_world(&engine.world, &physics_world)
}
