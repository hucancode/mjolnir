package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    for z in 0 ..< 5 {
      for x in 0 ..< 5 {
        mjolnir.spawn_primitive_mesh(
          engine,
          .CUBE,
          .YELLOW,
          {f32(x - 2) * 4, 0, f32(z - 2) * 4},
        )
      }
    }
    world.main_camera_look_at(
      &engine.world,
      {10, 15, 10},
      {0, 0, 0},
    )
  }
  mjolnir.run(engine, 800, 600, "Cube 5x5")
}
