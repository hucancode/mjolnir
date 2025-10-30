package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mat := engine.rm.builtin_materials[resources.Color.GREEN]
    mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
    for z in 0 ..< 300 {
      for x in 0 ..< 300 {
        handle := mjolnir.spawn(
          engine,
          world.MeshAttachment{handle = mesh, material = mat},
        ) or_continue
        mjolnir.translate(
          engine,
          handle,
          f32(x - 150) * 4,
          0,
          f32(z - 150) * 4,
        )
      }
    }
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      resources.camera_look_at(camera, {6, 20, 6}, {0, 0, 0})
    }
  }
  mjolnir.run(engine, 800, 600, "visual-grid-300")
}
