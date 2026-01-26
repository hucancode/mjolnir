package main

import "../../mjolnir"
import "../../mjolnir/resources"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

nodes: [dynamic]resources.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    using mjolnir
    if camera := get_main_camera(engine); camera != nil {
      camera_look_at(camera, {1.5, 1.5, 1.5}, {0, 1, 0})
      sync_active_camera_controller(engine)
    }
    nodes = load_gltf(engine, "assets/CesiumMan.glb")
    q1 := linalg.quaternion_angle_axis(math.PI * -0.4, linalg.VECTOR3F32_X_AXIS)
    q2 := linalg.quaternion_angle_axis(math.PI * 0.35, linalg.VECTOR3F32_Y_AXIS)
    handle := spawn_directional_light(
      engine,
      {1.0, 1.0, 1.0, 1.0},
      rotation = q2 * q1,
      cast_shadow = true,
    )
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.15
    for handle in nodes {
      mjolnir.rotate_by(engine, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-skinning")
}
