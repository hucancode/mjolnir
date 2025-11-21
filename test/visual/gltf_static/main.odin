package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:time"

nodes: [dynamic]resources.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    using mjolnir
    if camera := get_main_camera(engine); camera != nil {
      camera_look_at(camera, {3, 4, 3}, {0.0, 2.0, 0.0})
    }
    nodes = load_gltf(engine, "assets/Duck.glb")
    spawn_directional_light(
      engine,
      {1.0, 1.0, 1.0, 1.0},
      cast_shadow = false,
      position = {-4.0, 6.0, 2.0},
    )
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.5
    for handle in nodes {
      mjolnir.rotate_by(engine, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-static")
}
