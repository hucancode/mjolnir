package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"

main :: proc() {
  mjolnir.run_app({
    title = "Cube",
    setup = proc(engine: ^mjolnir.Engine) {
      mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
      render.main_camera_look_at(&engine.render, {3, 2, 3}, {0, 0, 0})
    },
    update = proc(engine: ^mjolnir.Engine, dt: f32) {
      world.update(&engine.world)
      for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
      for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
    },
  })
}
