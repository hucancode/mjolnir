package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:time"

nodes: [dynamic]world.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      transmute(world.CameraHandle)engine.render.main_camera,
      {5, 6, 5},
      {0, 5, 0},
    )
    nodes = mjolnir.load_gltf(engine, "assets/Duck.glb")
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
    rotation := delta_time * math.PI * 0.5
    for handle in nodes {
      world.rotate_by(&engine.world, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-static")
}
