package main

import "../../mjolnir"
import "../../mjolnir/world"

main :: proc() {
  mjolnir.run_app({
    title = "Cube",
    setup = proc(engine: ^mjolnir.Engine) {
      world.spawn_primitive_mesh(&engine.world, .CUBE, .RED)
      world.main_camera_look_at(&engine.world, {3, 2, 3}, {0, 0, 0})
    },
  })
}
