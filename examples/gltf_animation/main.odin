package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/resources"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import cgltf "vendor:cgltf"
import "vendor:glfw"

root_nodes: [dynamic]resources.NodeHandle
frame_counter: int

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      mjolnir.camera_look_at(camera, {1.5, 1.5, 1.5}, {0, 1, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
    root_nodes = mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
    for handle in root_nodes {
      node := mjolnir.get_node(engine, handle) or_continue
      for child in node.children {
        if mjolnir.play_animation(engine, child, "Anim_0") do break
      }
    }
    mjolnir.spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.05
    for handle in root_nodes {
      mjolnir.rotate_by(engine, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-animation")
}
