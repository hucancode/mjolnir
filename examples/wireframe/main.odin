package main

import "../../mjolnir"
import "core:math/linalg"

main :: proc() {
  mjolnir.run_app({title = "Wireframe", setup = setup, update = update})
}

handles: [9]mjolnir.NodeHandle

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {0, 4, 9}, {0, 0, 0})

  cube := mjolnir.builtin_mesh(engine, .CUBE)
  mat := mjolnir.material_wireframe(engine)

  for i in 0 ..< 9 {
    row := i / 3
    col := i % 3
    x := f32(col - 1) * 2.5
    z := f32(row - 1) * 2.5
    h := mjolnir.spawn_mesh(engine, cube, mat, {x, 0, z}, cast_shadow = false)
    mjolnir.scale(engine, h, 0.7)
    handles[i] = h
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  t := mjolnir.time_since_start(engine)
  axis := linalg.normalize([3]f32{1, 1, 0.4})
  for h, i in handles {
    mjolnir.rotate(engine, h, linalg.quaternion_angle_axis(t * (0.4 + f32(i) * 0.15), axis))
  }
}
