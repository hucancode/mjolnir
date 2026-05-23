package main

import "../../mjolnir"
import "core:math"

nodes: [dynamic]mjolnir.NodeHandle

main :: proc() {
  mjolnir.run_app({
    title  = "GLTF Static",
    setup  = proc(engine: ^mjolnir.Engine) {
      mjolnir.main_camera_look_at(engine, {5, 6, 5}, {0, 5, 0})
      nodes = mjolnir.load_gltf(engine, "assets/Duck.glb")
      mjolnir.spawn_light_directional(engine)
    },
    update = proc(engine: ^mjolnir.Engine, dt: f32) {
      rot := dt * math.PI * 0.5
      for h in nodes do mjolnir.rotate_by(engine, h, rot)
    },
  })
}
