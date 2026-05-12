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

  ground := world.spawn_primitive_mesh(
    &engine.world,
    .QUAD_XZ,
    .GRAY,
    cast_shadow = false,
  )
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
      features = {.ALBEDO_TEXTURE},
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

  world.spawn_light_directional(
    &engine.world,
    position = {2, 6, 4},
    color    = {1, 1, 1, 1},
    radius   = 8,
  )
}
