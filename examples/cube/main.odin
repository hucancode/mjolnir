package main

import "../../mjolnir"
import "../../mjolnir/render"

main :: proc() {
  mjolnir.run_app({
    title = "Cube",
    setup = proc(engine: ^mjolnir.Engine) {
      mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
      render.main_camera_look_at(&engine.render, {3, 2, 3}, {0, 0, 0})
    },
  })
}
