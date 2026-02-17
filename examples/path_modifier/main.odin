package main

import "../../mjolnir"
import "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/gpu"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      {5, 15, 8},
      {0, 3, 0},
    )
    root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")

    CONTROL_POINTS :: 8
    path := make([][3]f32, CONTROL_POINTS)
    defer delete(path)

    // Create a compact S-curve that matches snake's natural length
    for i in 0 ..< CONTROL_POINTS {
      t := f32(i) / f32(CONTROL_POINTS - 1)
      x := f32(3.0 * math.sin(t * math.PI * 2.0))
      y := f32(t * 5.0) // Vertical progression
      z := f32(0.0)
      path[i] = [3]f32{x, y, z}
    }

    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        world.add_path_modifier_layer(
          &engine.world,
          child,
          root_bone_name = "root",
          tail_length = 14,
          path = path,
          offset = 0.0,
          length = 3.0, // Fit skeleton to a 20-unit segment of the path
          speed = 5.0, // Disabled animation
          loop = true,
          weight = 1.0,
        )
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
    point_light_handle :=
      world.spawn(
        &engine.world,
        {20, 20, 40},
        world.create_point_light_attachment({1.0, 0.9, 0.8, 1.0}, 500.0, true),
      ) or_else {}
  }
  mjolnir.run(engine, 800, 600, "Path Modifier")
}
