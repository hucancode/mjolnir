package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  mjolnir.run(engine, 800, 600, "Transparent")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {6, 3, 6}, {0, 1, 0})

  ground := world.spawn_primitive_mesh(&engine.world, .QUAD_XZ, .GRAY, cast_shadow=false)
  world.scale(&engine.world, ground, 6.0)

  // Solid red sphere behind the glass slabs
  red_mat := world.material_pbr(&engine.world, {0.95, 0.15, 0.15, 1}, roughness=0.4)
  world.spawn_mesh(
    &engine.world,
    world.get_builtin_mesh(&engine.world, .SPHERE),
    red_mat,
    {0, 1, -2},
  )

  // Stack of transparent quads, increasing opacity
  cube := world.get_builtin_mesh(&engine.world, .CUBE)
  colors := [4][4]f32 {
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for c, i in colors {
    mat := world.material_transparent(&engine.world, c)
    h := world.spawn_mesh(
      &engine.world,
      cube,
      mat,
      {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4},
      cast_shadow = false,
    )
    world.scale(&engine.world, h, 0.8)
  }

  world.spawn_light_directional(
    &engine.world,
    position    = {3, 6, 3},
    color       = {1, 0.97, 0.9, 1},
    radius      = 10,
    cast_shadow = true,
  )
}
