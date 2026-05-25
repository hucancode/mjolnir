package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:math"

root_nodes: [dynamic]world.NodeHandle

main :: proc() {
  mjolnir.run_app({
    title  = "GLTF Animation",
    setup  = setup,
    update = update,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {1.5, 1.5, 1.5}, {0, 1, 0})
  root_nodes = mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
  for handle in root_nodes {
    node := world.node(&engine.world, handle) or_continue
    for child in node.children {
      if world.play_animation(&engine.world, child, "Anim_0") do break
    }
  }
  world.spawn_light_directional(&engine.world)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  rot := dt * math.PI * 0.05
  for h in root_nodes do world.rotate_by(&engine.world, h, rot)
}
