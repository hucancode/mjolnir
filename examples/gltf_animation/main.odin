package main

import "../../mjolnir"
import "core:math"

root_nodes: [dynamic]mjolnir.NodeHandle

main :: proc() {
  mjolnir.run_app({
    title  = "GLTF Animation",
    setup  = setup,
    update = update,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {1.5, 1.5, 1.5}, {0, 1, 0})
  root_nodes = mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
  for handle in root_nodes {
    node := mjolnir.node(engine, handle) or_continue
    for child in node.children {
      if mjolnir.play_animation(engine, child, "Anim_0") do break
    }
  }
  mjolnir.spawn_light_directional(engine)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  rot := dt * math.PI * 0.05
  for h in root_nodes do mjolnir.rotate_by(engine, h, rot)
}
