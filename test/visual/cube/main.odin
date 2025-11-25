package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mat := engine.rm.builtin_materials[resources.Color.RED]
    mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
    handle := mjolnir.spawn(
      engine,
      attachment = world.MeshAttachment{handle = mesh, material = mat},
    )
    mjolnir.translate(engine, handle, 0, 0, 0)
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      mjolnir.camera_look_at(camera, {3, 2, 3}, {0, 0, 0})
    }
  }
  mjolnir.run(engine, 800, 600, "visual-single-cube")
}
