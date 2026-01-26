package main

import "../../mjolnir"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    for z in 0 ..< 5 {
      for x in 0 ..< 5 {
        mjolnir.spawn_cube(engine, .YELLOW, {f32(x - 2) * 4, 0, f32(z - 2) * 4})
      }
    }
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      mjolnir.camera_look_at(camera, {10, 15, 10}, {0, 0, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-grid-5")
}
