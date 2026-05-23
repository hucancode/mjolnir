package main

import "../../mjolnir"

main :: proc() {
  mjolnir.run_app({title = "Transparent", setup = setup})
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {6, 3, 6}, {0, 1, 0})

  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, cast_shadow = false)
  mjolnir.scale(engine, ground, 6.0)

  // Solid red sphere behind the glass slabs
  red_mat := mjolnir.material_pbr(engine, {0.95, 0.15, 0.15, 1}, roughness = 0.4)
  mjolnir.spawn_mesh(engine, mjolnir.builtin_mesh(engine, .SPHERE), red_mat, {0, 1, -2})

  // Stack of transparent quads, increasing opacity
  cube := mjolnir.builtin_mesh(engine, .CUBE)
  colors := [4][4]f32{
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for c, i in colors {
    mat := mjolnir.material_transparent(engine, c)
    h := mjolnir.spawn_mesh(engine, cube, mat, {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4}, cast_shadow = false)
    mjolnir.scale(engine, h, 0.8)
  }

  mjolnir.spawn_light_directional(
    engine,
    position    = {3, 6, 3},
    color       = {1, 0.97, 0.9, 1},
    radius      = 10,
    cast_shadow = true,
  )
}
