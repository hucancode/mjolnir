package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import cgltf "vendor:cgltf"
import "vendor:glfw"

root_nodes: [dynamic]world.NodeHandle
frame_counter: int

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      engine.world.main_camera,
      {1.5, 1.5, 1.5},
      {0, 1, 0},
    )
    root_nodes = mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        if world.play_animation(&engine.world, child, "Anim_0") do break
      }
    }
    light_handle :=
      world.spawn(
        &engine.world,
        {0, 0, 0},
        world.create_directional_light_attachment(
          {1.0, 1.0, 1.0, 1.0},
          10.0,
          false,
        ),
      ) or_else {}
    world.register_active_light(&engine.world, light_handle)
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.05
    for handle in root_nodes {
      world.rotate_by(&engine.world, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-animation")
}
