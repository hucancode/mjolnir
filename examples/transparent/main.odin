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

  plane := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  plane_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground := world.spawn(
    &engine.world,
    {0, 0, 0},
    world.MeshAttachment{handle = plane, material = plane_mat, cast_shadow = false},
  ) or_else {}
  world.scale(&engine.world, ground, 6.0)

  // Solid red sphere behind the glass slabs
  sphere := world.get_builtin_mesh(&engine.world, .SPHERE)
  red_mat := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {0.95, 0.15, 0.15, 1},
    roughness_value = 0.4,
  ) or_else {}
  back := world.spawn(
    &engine.world,
    {0, 1, -2},
    world.MeshAttachment{handle = sphere, material = red_mat, cast_shadow = true},
  ) or_else {}
  _ = back

  // Stack of transparent quads, increasing opacity
  cube := world.get_builtin_mesh(&engine.world, .CUBE)
  colors := [4][4]f32 {
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for c, i in colors {
    mat := world.create_material(
      &engine.world,
      type = .TRANSPARENT,
      base_color_factor = c,
    ) or_else {}
    h := world.spawn(
      &engine.world,
      {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4},
      world.MeshAttachment{handle = cube, material = mat, cast_shadow = false},
    ) or_else {}
    world.scale(&engine.world, h, 0.8)
  }

  world.spawn(
    &engine.world,
    {3, 6, 3},
    world.create_directional_light_attachment({1, 0.97, 0.9, 1}, 10, true),
  )
}
