package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mat := world.get_builtin_material(&engine.world, .GREEN)
    mesh := world.get_builtin_mesh(&engine.world, .CUBE)
    for z in 0 ..< 300 {
      for x in 0 ..< 300 {
        handle := world.spawn(
          &engine.world,
          {0, 0, 0},
          attachment = world.MeshAttachment{handle = mesh, material = mat},
        ) or_continue
        world.translate(
          &engine.world,
          handle,
          f32(x - 150) * 4,
          0,
          f32(z - 150) * 4,
        )
      }
    }
    world.main_camera_look_at(
      &engine.world,
      engine.world.main_camera,
      {6, 20, 6},
      {0, 0, 0},
    )
  }
  mjolnir.run(engine, 800, 600, "Cube 300x300")
}
