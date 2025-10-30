package main

import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mat := engine.rm.builtin_materials[resources.Color.RED]
    mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
    handle := mjolnir.spawn(
      engine,
      world.MeshAttachment{handle = mesh, material = mat},
    )
    mjolnir.translate(engine, handle, 0, 0, 0)
    camera := mjolnir.get_main_camera(engine)
    if camera != nil do resources.camera_look_at(camera, {3, 2, 3}, {0, 0, 0})
  }
  mjolnir.run(engine, 800, 600, "visual-single-cube")
}
