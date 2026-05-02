package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

light_handle: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Directional Light")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(
    &engine.world,
    {7.0, 6.0, 7.0},
    {0.0, 0.5, 0.0},
  )

  plane_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  plane_material := world.get_builtin_material(&engine.world, .GRAY)
  plane_handle :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      attachment = world.MeshAttachment {
        handle = plane_mesh,
        material = plane_material,
        cast_shadow = false,
      },
    ) or_else {}
  world.scale(&engine.world, plane_handle, 10.0)

  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  torus_mesh := world.get_builtin_mesh(&engine.world, .TORUS)

  red := world.get_builtin_material(&engine.world, .RED)
  green := world.get_builtin_material(&engine.world, .GREEN)
  blue := world.get_builtin_material(&engine.world, .BLUE)
  yellow := world.get_builtin_material(&engine.world, .YELLOW)
  cyan := world.get_builtin_material(&engine.world, .CYAN)

  spawn_caster :: proc(
    engine: ^mjolnir.Engine,
    mesh: world.MeshHandle,
    mat: world.MaterialHandle,
    pos: [3]f32,
    s: f32,
  ) {
    h :=
      world.spawn(
        &engine.world,
        pos,
        attachment = world.MeshAttachment {
          handle = mesh,
          material = mat,
          cast_shadow = true,
        },
      ) or_else {}
    world.scale(&engine.world, h, s)
  }

  // ground-resting reference objects
  spawn_caster(engine, cube_mesh, red, {-2.5, 0.6, -1.5}, 0.6)
  spawn_caster(engine, sphere_mesh, blue, {-1.0, 0.8, 2.0}, 0.8)
  // floating objects so shadow on ground is detached from the caster
  spawn_caster(engine, cube_mesh, green, {2.0, 2.5, 1.0}, 0.7)
  spawn_caster(engine, sphere_mesh, yellow, {2.5, 3.0, -2.5}, 0.5)
  spawn_caster(engine, torus_mesh, cyan, {0.0, 3.5, 0.0}, 0.9)

  light_handle =
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.create_directional_light_attachment(
        {1.0, 0.95, 0.85, 1.5},
        12.0,
        true,
      ),
    ) or_else {}
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  // Tilt 60° from vertical (long shadows) and sweep azimuth around Y.
  q_tilt := linalg.quaternion_angle_axis(
    math.PI * (1.0 / 3.0),
    linalg.VECTOR3F32_X_AXIS,
  )
  q_yaw := linalg.quaternion_angle_axis(
    t * 0.8,
    linalg.VECTOR3F32_Y_AXIS,
  )
  world.rotate(&engine.world, light_handle, q_yaw * q_tilt)
}
