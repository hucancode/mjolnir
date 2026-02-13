package main

import "../../mjolnir"
import world "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mjolnir.spawn_cube(engine, .RED)
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      world.camera_look_at(camera, {3, 2, 3}, {0, 0, 0})
    }
  }
  mjolnir.run(engine, 800, 600, "visual-single-cube")
}
