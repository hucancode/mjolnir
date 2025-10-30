package main

import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  mjolnir.run(engine, 800, 600, "visual-postprocess-crosshatch")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  mat1 := engine.rm.builtin_materials[resources.Color.YELLOW]
  mat2 := engine.rm.builtin_materials[resources.Color.BLUE]
  mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  half := f32(2.0)
  for z in 0 ..< 5 {
    for x in 0 ..< 5 {
      mat := mat1 if (x + z) % 2 == 0 else mat2
      handle := mjolnir.spawn(
        engine,
        world.MeshAttachment{handle = mesh, material = mat},
      )
      mjolnir.translate(
        engine,
        handle,
        (f32(x) - half) * 1.6,
        0,
        (f32(z) - half) * 1.6,
      )
      mjolnir.scale(engine, handle, 0.45)
    }
  }

  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {7.5, 6.0, 7.5}, {0, 0, 0})
  }
  mjolnir.add_crosshatch(
    engine,
    resolution = {800, 600},
    hatch_offset_y = 5.0,
    lum_threshold_01 = 0.6,
    lum_threshold_02 = 0.3,
    lum_threshold_03 = 0.15,
    lum_threshold_04 = 0.07,
  )
}
