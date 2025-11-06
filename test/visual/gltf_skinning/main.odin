package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

nodes: [dynamic]resources.Handle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    using mjolnir
    if camera := get_main_camera(engine); camera != nil {
      camera_look_at(camera, {1.5, 1.5, 1.5}, {0, 1, 0})
    }
    nodes = load_gltf(engine, "assets/CesiumMan.glb")
    handle := spawn_directional_light(
      engine,
      {1.0, 1.0, 1.0, 1.0},
      cast_shadow = true,
      position = {-3.0, 5.0, -2.0},
    )
    rotate(engine, handle, math.PI * -0.4, linalg.VECTOR3F32_X_AXIS)
    rotate(engine, handle, math.PI * 0.35)
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.15
    for handle in nodes {
      mjolnir.rotate_by(engine, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-skinning")
}
