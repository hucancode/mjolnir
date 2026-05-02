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
  mjolnir.run(engine, 800, 600, "Spot Light")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(
    &engine.world,
    {6.0, 4.0, 6.0},
    {0.0, 0.0, 0.0},
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
  world.scale(&engine.world, plane_handle, 6.5)
  world.translate(&engine.world, plane_handle, 0.0, -0.05, 0.0)
  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  sphere_material := world.get_builtin_material(&engine.world, .RED)
  sphere_handle :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      attachment = world.MeshAttachment {
        handle = sphere_mesh,
        material = sphere_material,
        cast_shadow = true,
      },
    ) or_else {}
  world.translate(&engine.world, sphere_handle, 0.0, 1.2, 0.0)
  world.scale(&engine.world, sphere_handle, 1.1)
  light_handle =
    world.spawn(
      &engine.world,
      {0, 6, 0},
      world.create_spot_light_attachment(
        {0.6, 0.8, 1.0, 1.0},
        18.0,
        math.PI * 0.15,
        true,
      ),
    ) or_else {}
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  world.rotate(
    &engine.world,
    light_handle,
    math.PI * 0.5 + math.sin(t) * 0.2,
    linalg.VECTOR3F32_X_AXIS,
  )
}
