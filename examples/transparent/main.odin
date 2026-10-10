package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"

main :: proc() {
  mjolnir.run_app({title = "Transparent", setup = setup})
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {6, 3, 6}, {0, 1, 0})

  mjolnir.spawn_ground(engine, 6.0)

  // Solid red sphere behind the glass slabs
  red_mat := render.material_pbr(&engine.render, {0.95, 0.15, 0.15, 1}, roughness = 0.4)
  mjolnir.spawn_mesh(engine, render.get_builtin_mesh(&engine.render, .SPHERE), red_mat, {0, 1, -2})

  // Stack of transparent quads, increasing opacity
  cube := render.get_builtin_mesh(&engine.render, .CUBE)
  colors := [4][4]f32{
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for c, i in colors {
    mat := render.material_transparent(&engine.render, c)
    h := mjolnir.spawn_mesh(engine, cube, mat, {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4}, cast_shadow = false)
    world.scale(&engine.world, h, 0.8)
  }

  mjolnir.spawn(engine, {3, 6, 3}, render.directional_light_attachment(
    color       = {1, 0.97, 0.9, 1},
    radius      = 10,
    cast_shadow = true,
  ))
}
