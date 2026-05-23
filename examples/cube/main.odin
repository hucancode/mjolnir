package main

import "../../mjolnir"

main :: proc() {
  mjolnir.run_app({
    title = "Cube",
    setup = proc(engine: ^mjolnir.Engine) {
      mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
      mjolnir.main_camera_look_at(engine, {3, 2, 3}, {0, 0, 0})
    },
  })
}
