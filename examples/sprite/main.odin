package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  mjolnir.run_app({title = "Sprite", setup = setup})
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {0, 1.5, 6}, {0, 1.5, 0})

  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, cast_shadow = false)
  mjolnir.scale(engine, ground, 6.0)

  tex, tex_ok := mjolnir.create_texture(engine, "assets/Warrior_Sheet-Effect.png")
  if !tex_ok {
    log.error("failed to load warrior sheet")
    return
  }
  quad := mjolnir.builtin_mesh(engine, .QUAD_XY)

  modes := [3]world.SpriteAnimationMode{.LOOP, .PINGPONG, .ONCE}
  xs := [3]f32{-3.0, 0.0, 3.0}

  for mode, i in modes {
    anim := world.sprite_animation_init(frame_count = 99, fps = 24.0, mode = mode)
    sprite, sprite_ok := world.create_sprite(&engine.world, tex, frame_columns = 6, frame_rows = 17, animation = anim)
    if !sprite_ok do continue
    mat, mat_ok := mjolnir.create_material(engine, features = {.ALBEDO_TEXTURE}, type = .TRANSPARENT, albedo_handle = tex)
    if !mat_ok do continue
    handle, ok := mjolnir.spawn(engine, {xs[i], 1.5, 0}, world.SpriteAttachment{sprite_handle = sprite, mesh_handle = quad, material = mat})
    if ok do mjolnir.scale(engine, handle, 2.5)
  }

  mjolnir.spawn_light_directional(engine, position = {2, 6, 4}, color = {1, 1, 1, 1}, radius = 8)
}
