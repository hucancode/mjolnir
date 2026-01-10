package main

import "../../../mjolnir"
import "../../../mjolnir/animation"
import "../../../mjolnir/geometry"
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
      camera_look_at(camera, {50, 15, 80}, {0, 12, 0})
      sync_active_camera_controller(engine)
    }
    root_nodes = load_gltf(engine, "assets/stuffed_snake_rigged.glb")

    CONTROL_POINTS :: 8
    path := make([][3]f32, CONTROL_POINTS)
    defer delete(path)

    // Create a compact S-curve that matches snake's natural length
    for i in 0 ..< CONTROL_POINTS {
      t := f32(i) / f32(CONTROL_POINTS - 1)
      // S-curve using sine wave
      x := f32(15.0 * math.sin(t * math.PI * 2.0))
      y := f32(t * 25.0)  // Vertical progression
      z := f32(0.0)
      path[i] = [3]f32{x, y, z}
    }

    for handle in root_nodes {
      node := get_node(engine, handle) or_continue
      for child in node.children {
        world.add_path_modifier_layer(
          &engine.world,
          &engine.rm,
          child,
          root_bone_name = "root",
          tail_length = 14,
          path = path,
          offset = 0.0,
          speed = 1.0,
          loop = true,
          weight = 1.0,
        )
      }
    }

    cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
    mat := engine.rm.builtin_materials[resources.Color.YELLOW]
    for point in path {
      marker := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = mat,
        },
      )
      scale(engine, marker, 3.0)
      translate(engine, marker, point.x, point.y, point.z)
    }

    spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
    spawn_point_light(
      engine,
      {1.0, 0.9, 0.8, 1.0},
      500.0,
      position = {20, 20, 40},
    )
  }
  mjolnir.run(engine, 800, 600, "visual-path-modifier")
}
