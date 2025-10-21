package main

import "core:log"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/world"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  mjolnir.run(engine, 800, 600, "visual-postprocess-crosshatch")
}

setup :: proc(engine: ^mjolnir.Engine) {
  mat1, _ := mjolnir.create_material(engine, type = .UNLIT, base_color_factor = {0.93, 0.75, 0.2, 1.0})
  mat2, _ := mjolnir.create_material(engine, type = .UNLIT, base_color_factor = {0.1, 0.55, 0.95, 1.0})
  cube := geometry.make_cube()
  mesh, _ := mjolnir.create_mesh(engine, cube)
  half := f32(2.0)
  for z in 0 ..< 5 {
    for x in 0 ..< 5 {
      mat := mat1 if (x + z) % 2 == 0 else mat2
      _, node, _ := mjolnir.spawn(engine, world.MeshAttachment{handle = mesh, material = mat})
      mjolnir.translate(node, (f32(x) - half) * 1.6, 0, (f32(z) - half) * 1.6)
      mjolnir.scale(node, 0.45)
    }
  }
  camera := mjolnir.get_main_camera(engine)
  if camera != nil do mjolnir.camera_look_at(camera, {7.5, 6.0, 7.5}, {0, 0, 0})
  mjolnir.add_crosshatch(engine, resolution = {800, 600}, hatch_offset_y = 5.0, lum_threshold_01 = 0.6, lum_threshold_02 = 0.3, lum_threshold_03 = 0.15, lum_threshold_04 = 0.07)
}
