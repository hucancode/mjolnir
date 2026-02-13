package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    mat1 := world.get_builtin_material(&engine.world, .YELLOW)
    mat2 := world.get_builtin_material(&engine.world, .BLUE)
    mesh := world.get_builtin_mesh(&engine.world, .CUBE)
    half := f32(2.0)
    for z in 0 ..< 5 {
      for x in 0 ..< 5 {
        mat := mat1 if (x + z) % 2 == 0 else mat2
        handle := mjolnir.spawn(
          engine,
          attachment = world.MeshAttachment{handle = mesh, material = mat},
        )
        world.translate(&engine.world,
          handle,
          (f32(x) - half) * 2.5,
          0,
          (f32(z) - half) * 2.5,
        )
      }
    }
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      world.camera_look_at(camera, {8, 6, 8}, {0, 0, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
    mjolnir.add_crosshatch(engine, resolution = {800, 600})
  }
  mjolnir.run(engine, 800, 600, "visual-postprocess-crosshatch")
}
