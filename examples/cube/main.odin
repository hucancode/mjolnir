package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import world "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
    world.main_camera_look_at(&engine.world, {3, 2, 3}, {0, 0, 0})
  }
  mjolnir.run(engine, 800, 600, "Cube")
}
