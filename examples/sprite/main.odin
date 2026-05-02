package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  mjolnir.run(engine, 800, 600, "Sprite")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 1.5, 6}, {0, 1.5, 0})

  plane := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  plane_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground := world.spawn(
    &engine.world,
    {0, 0, 0},
    world.MeshAttachment{handle = plane, material = plane_mat, cast_shadow = false},
  ) or_else {}
  world.scale(&engine.world, ground, 6.0)

  tex, tex_ok := mjolnir.create_texture(engine, "assets/Warrior_Sheet-Effect.png")
  if !tex_ok {
    log.error("failed to load warrior sheet")
    return
  }
  quad := world.get_builtin_mesh(&engine.world, .QUAD_XY)

  modes := [3]world.SpriteAnimationMode{.LOOP, .PINGPONG, .ONCE}
  xs := [3]f32{-3.0, 0.0, 3.0}

  for mode, i in modes {
    anim := world.sprite_animation_init(
      frame_count = 99,
      fps = 24.0,
      mode = mode,
    )
    sprite, sprite_ok := world.create_sprite(
      &engine.world,
      tex,
      frame_columns = 6,
      frame_rows = 17,
      animation = anim,
    )
    if !sprite_ok do continue
    mat, mat_ok := world.create_material(
      &engine.world,
      {.ALBEDO_TEXTURE},
      type = .TRANSPARENT,
      albedo_handle = tex,
    )
    if !mat_ok do continue
    handle, ok := world.spawn(
      &engine.world,
      {xs[i], 1.5, 0},
      world.SpriteAttachment{sprite_handle = sprite, mesh_handle = quad, material = mat},
    )
    if ok {
      world.scale(&engine.world, handle, 2.5)
    }
  }

  world.spawn(
    &engine.world,
    {2, 6, 4},
    world.create_directional_light_attachment({1, 1, 1, 1}, 8, false),
  )
}
