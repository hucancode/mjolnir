package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math/linalg"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Wireframe")
}

handles: [9]world.NodeHandle

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 4, 9}, {0, 0, 0})

  cube := world.get_builtin_mesh(&engine.world, .CUBE)
  mat := world.create_material(&engine.world, type = .WIREFRAME) or_else {}

  for i in 0 ..< 9 {
    row := i / 3
    col := i % 3
    x := f32(col - 1) * 2.5
    z := f32(row - 1) * 2.5
    h := world.spawn(
      &engine.world,
      {x, 0, z},
      world.MeshAttachment{handle = cube, material = mat, cast_shadow = false},
    ) or_else {}
    world.scale(&engine.world, h, 0.7)
    handles[i] = h
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  axis := linalg.normalize([3]f32{1, 1, 0.4})
  for h, i in handles {
    if n, ok := world.node(&engine.world, h); ok {
      n.transform.rotation = linalg.quaternion_angle_axis(
        t * (0.4 + f32(i) * 0.15),
        axis,
      )
      n.transform.is_dirty = true
    }
  }
}
