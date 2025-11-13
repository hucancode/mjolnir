package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mat := engine.rm.builtin_materials[resources.Color.YELLOW]
    mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
    for z in 0 ..< 5 {
      for x in 0 ..< 5 {
        handle := mjolnir.spawn(
          engine,
          attachment = world.MeshAttachment{handle = mesh, material = mat},
        ) or_continue
        mjolnir.translate(engine, handle, f32(x - 2) * 4, 0, f32(z - 2) * 4)
      }
    }
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      resources.camera_look_at(camera, {10, 15, 10}, {0, 0, 0})
    }
  }
  mjolnir.run(engine, 800, 600, "visual-grid-5")
}
