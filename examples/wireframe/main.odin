package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/render/ambient"
import "../../mjolnir/world"
import "core:math/linalg"

main :: proc() {
  mjolnir.run_app({title = "Wireframe", setup = setup, update = update})
}

handles: [9]world.NodeHandle

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {0, 4, 9}, {0, 0, 0})
  ambient.set_skybox_enabled(&engine.render.ambient, false)

  cube := engine.render.builtin_meshes[.CUBE]
  mat := render.material_wireframe(&engine.render)

  for i in 0 ..< 9 {
    row := i / 3
    col := i % 3
    x := f32(col - 1) * 2.5
    z := f32(row - 1) * 2.5
    h := mjolnir.spawn_mesh(engine, cube, mat, {x, 0, z}, cast_shadow = false)
    world.scale(&engine.world, h, 0.7)
    handles[i] = h
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  t := mjolnir.time_since_start(engine)
  axis := linalg.normalize([3]f32{1, 1, 0.4})
  for h, i in handles {
    world.rotate(&engine.world, h, linalg.quaternion_angle_axis(t * (0.4 + f32(i) * 0.15), axis))
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}
