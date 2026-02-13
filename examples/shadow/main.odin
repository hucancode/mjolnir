package main

import "../../mjolnir"
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
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    world.camera_look_at(camera, {6.0, 4.5, 6.0}, {0.0, 0.8, 0.0})
    mjolnir.sync_active_camera_controller(engine)
  }
  plane_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  plane_material := world.get_builtin_material(&engine.world, .GRAY)
  plane_handle := mjolnir.spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = plane_mesh,
      material = plane_material,
      cast_shadow = false,
    },
  )
  world.scale(&engine.world, plane_handle, 7.0)
  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  cube_material := world.get_builtin_material(&engine.world, .WHITE)
  cube_handle := mjolnir.spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = cube_mesh,
      material = cube_material,
      cast_shadow = true,
    },
  )
  world.translate(&engine.world, cube_handle, 0.0, 1.5, 0.0)
  world.scale(&engine.world, cube_handle, 0.8)
  light_handle = mjolnir.spawn_spot_light(
    engine,
    {1.0, 0.95, 0.8, 3.5},
    radius = 18.0,
    angle = math.PI * 0.3,
    position = {0.0, 5.0, 0.0},
  )
  world.rotate(&engine.world, light_handle, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
}


update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  world.translate(&engine.world, light_handle, 0, math.sin(t) * 0.5 + 4.5, 0)
}
