package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  mjolnir.run_app({title = "Sprite", setup = setup})
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {0, 1.5, 6}, {0, 1.5, 0})

  mjolnir.spawn_ground(engine, 6.0)

  tex, tex_ret := render.create_texture_from_path(&engine.render, "assets/Warrior_Sheet-Effect.png")
  if tex_ret != .SUCCESS {
    log.error("failed to load warrior sheet")
    return
  }

  modes := [3]render.SpriteAnimationMode{.LOOP, .PINGPONG, .ONCE}
  xs := [3]f32{-3.0, 0.0, 3.0}

  for mode, i in modes {
    mat := render.create_material(&engine.render, features = {.ALBEDO_TEXTURE}, type = .TRANSPARENT, albedo_handle = tex) or_continue
    anim := render.sprite_animation_init(frame_count = 99, fps = 24.0, mode = mode)
    node, _, ok := mjolnir.spawn_sprite(engine, tex, {xs[i], 1.5, 0}, 6, 17, anim, material = mat)
    if ok do world.scale(&engine.world, node, 2.5)
  }

  mjolnir.spawn(engine, {2, 6, 4}, render.directional_light_attachment(color = {1, 1, 1, 1}, radius = 8))
}
