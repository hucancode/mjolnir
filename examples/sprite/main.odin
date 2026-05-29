package main

import "../../mjolnir"
import "../../mjolnir/gpu"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  mjolnir.run_app({title = "Sprite", setup = setup})
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 1.5, 6}, {0, 1.5, 0})

  world.spawn_ground(&engine.world, 6.0)

  tex, tex_ret := gpu.create_texture_2d_from_path(&engine.gctx, &engine.render.texture_manager, "assets/Warrior_Sheet-Effect.png")
  if tex_ret != .SUCCESS {
    log.error("failed to load warrior sheet")
    return
  }
  quad := world.get_builtin_mesh(&engine.world, .QUAD_XY)

  modes := [3]world.SpriteAnimationMode{.LOOP, .PINGPONG, .ONCE}
  xs := [3]f32{-3.0, 0.0, 3.0}

  for mode, i in modes {
    mat := world.create_material(&engine.world, features = {.ALBEDO_TEXTURE}, type = .TRANSPARENT, albedo_handle = tex) or_continue
    anim := world.sprite_animation_init(frame_count = 99, fps = 24.0, mode = mode)
    node, _, ok := world.spawn_sprite(&engine.world, tex, quad, mat, {xs[i], 1.5, 0}, 6, 17, anim)
    if ok do world.scale(&engine.world, node, 2.5)
  }

  world.spawn_light_directional(&engine.world, position = {2, 6, 4}, color = {1, 1, 1, 1}, radius = 8)
}
