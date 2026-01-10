package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"

root_nodes: [dynamic]resources.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    using mjolnir
    if camera := get_main_camera(engine); camera != nil {
      camera_look_at(camera, {0, 100, 150}, {0, 30, 0})
      sync_active_camera_controller(engine)
    }
    root_nodes = load_gltf(engine, "assets/stuffed_snake_rigged.glb")
    for handle in root_nodes {
      node := get_node(engine, handle) or_continue
      for child in node.children {
        success := world.add_tail_modifier_layer(
          &engine.world,
          &engine.rm,
          child,
          root_bone_name = "root",
          tail_length = 14,
          frequency = 2.0,
          amplitude = 0.4,
          propagation_speed = 1.5,
          damping = 0.85,
          weight = 1.0,
        )
        if success {
          log.infof("Added tail modifier to node")
        }
      }
    }
    spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
    spawn_point_light(
      engine,
      {1.0, 0.9, 0.8, 1.0},
      1000.0,
      position = {0, 50, 50},
    )
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.1
    for handle in root_nodes {
      mjolnir.rotate_by(engine, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-tail-modifier")
}
