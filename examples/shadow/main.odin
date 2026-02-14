package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import "vendor:glfw"

light_handle: world.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-shadow-casting")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(
    &engine.world,
    transmute(world.CameraHandle)engine.render.main_camera,
    {6.0, 4.5, 6.0},
    {0.0, 0.8, 0.0},
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
  world.scale(&engine.world, plane_handle, 7.0)
  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  cube_material := world.get_builtin_material(&engine.world, .WHITE)
  cube_handle :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      attachment = world.MeshAttachment {
        handle = cube_mesh,
        material = cube_material,
        cast_shadow = true,
      },
    ) or_else {}
  world.translate(&engine.world, cube_handle, 0.0, 1.5, 0.0)
  world.scale(&engine.world, cube_handle, 0.8)
  light_handle =
    world.spawn(
      &engine.world,
      {0.0, 5.0, 0.0},
      world.create_spot_light_attachment(
        {1.0, 0.95, 0.8, 3.5},
        18.0,
        math.PI * 0.3,
        true,
      ),
    ) or_else {}
  world.register_active_light(&engine.world, light_handle)
  world.rotate(
    &engine.world,
    light_handle,
    math.PI * 0.5,
    linalg.VECTOR3F32_X_AXIS,
  )
}


update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  world.translate(&engine.world, light_handle, 0, math.sin(t) * 0.5 + 4.5, 0)
}
