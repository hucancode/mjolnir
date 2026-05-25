package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:math"

nodes: [dynamic]world.NodeHandle

main :: proc() {
  mjolnir.run_app({
    title  = "GLTF Static",
    setup  = proc(engine: ^mjolnir.Engine) {
      world.main_camera_look_at(&engine.world, {5, 6, 5}, {0, 5, 0})
      nodes = mjolnir.load_gltf(engine, "assets/Duck.glb")
      world.spawn_light_directional(&engine.world)
    },
    update = proc(engine: ^mjolnir.Engine, dt: f32) {
      rot := dt * math.PI * 0.5
      for h in nodes do world.rotate_by(&engine.world, h, rot)
    },
  })
}
