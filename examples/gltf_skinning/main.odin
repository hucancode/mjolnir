package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

nodes: [dynamic]world.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      engine.world.main_camera,
      {1.5, 1.5, 1.5},
      {0, 1, 0},
    )
    nodes = mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
    q1 := linalg.quaternion_angle_axis(
      math.PI * -0.4,
      linalg.VECTOR3F32_X_AXIS,
    )
    q2 := linalg.quaternion_angle_axis(
      math.PI * 0.35,
      linalg.VECTOR3F32_Y_AXIS,
    )
    handle :=
      world.spawn(
        &engine.world,
        {0, 0, 0},
        world.create_directional_light_attachment(
          {1.0, 1.0, 1.0, 1.0},
          10.0,
          true,
        ),
      ) or_else {}
    if light_node, ok := cont.get(engine.world.nodes, handle); ok {
      light_node.transform.rotation = q2 * q1
      light_node.transform.is_dirty = true
    }
    world.register_active_light(&engine.world, handle)
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    rotation := delta_time * math.PI * 0.15
    for handle in nodes {
      world.rotate_by(&engine.world, handle, rotation)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-gltf-skinning")
}
