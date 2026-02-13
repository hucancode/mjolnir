package main

import "../../mjolnir"
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
        handle := mjolnir.spawn(
          engine,
          attachment = world.MeshAttachment{handle = mesh, material = mat},
        ) or_continue
        world.translate(&engine.world,
          handle,
          f32(x - 150) * 4,
          0,
          f32(z - 150) * 4,
        )
      }
    }
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      world.camera_look_at(camera, {6, 20, 6}, {0, 0, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-grid-300")
}
