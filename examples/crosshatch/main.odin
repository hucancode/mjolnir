package main

import "../../mjolnir"
import "../../mjolnir/resources"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mat1 := engine.rm.builtin_materials[resources.Color.YELLOW]
    mat2 := engine.rm.builtin_materials[resources.Color.BLUE]
    mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
    half := f32(2.0)
    for z in 0 ..< 5 {
      for x in 0 ..< 5 {
        mat := mat1 if (x + z) % 2 == 0 else mat2
        handle := mjolnir.spawn(
          engine,
          attachment = world.MeshAttachment{handle = mesh, material = mat},
        )
        mjolnir.translate(
          engine,
          handle,
          (f32(x) - half) * 2.5,
          0,
          (f32(z) - half) * 2.5,
        )
      }
    }
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      mjolnir.camera_look_at(camera, {8, 6, 8}, {0, 0, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
    mjolnir.add_crosshatch(engine, resolution = {800, 600})
  }
  mjolnir.run(engine, 800, 600, "visual-postprocess-crosshatch")
}
