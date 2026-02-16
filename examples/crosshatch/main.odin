package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import post_process "../../mjolnir/render/post_process"
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
        handle :=
          world.spawn(
            &engine.world,
            {0, 0, 0},
            world.MeshAttachment{handle = mesh, material = mat},
          ) or_else {}
        world.translate(
          &engine.world,
          handle,
          (f32(x) - half) * 2.5,
          0,
          (f32(z) - half) * 2.5,
        )
      }
    }
    world.main_camera_look_at(
      &engine.world,
      {8, 6, 8},
      {0, 0, 0},
    )
    post_process.add_crosshatch(&engine.render.post_process, {800, 600})
  }
  mjolnir.run(engine, 800, 600, "Crosshatch")
}
