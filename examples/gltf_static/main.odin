package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:time"

nodes: [dynamic]world.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      world.camera_look_at(camera, {5, 6, 5}, {0, 5, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
    nodes = mjolnir.load_gltf(engine, "assets/Duck.glb")
    mjolnir.spawn_directional_light(
      engine,
      {1.0, 1.0, 1.0, 1.0},
      cast_shadow = false,
    )
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.5
    for handle in nodes {
      world.rotate_by(&engine.world, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-static")
}
