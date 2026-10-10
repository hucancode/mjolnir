package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"

FRAME_COUNT :: 99
FPS :: 24.0

Mode :: enum {
  LOOP,
  PINGPONG,
  ONCE,
}

sprites: [Mode]render.SpriteHandle
elapsed: f32

main :: proc() {
  mjolnir.run_app({title = "Sprite", setup = setup, update = update})
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {0, 1.5, 6}, {0, 1.5, 0})

  mjolnir.spawn_ground(engine, 6.0)

  tex, tex_ret := render.create_texture_from_path(&engine.render, "assets/Warrior_Sheet-Effect.png")
  if tex_ret != .SUCCESS {
    log.error("failed to load warrior sheet")
    return
  }

  xs := [Mode]f32{.LOOP = -3.0, .PINGPONG = 0.0, .ONCE = 3.0}
  for x, mode in xs {
    mat := render.create_material(&engine.render, features = {.ALBEDO_TEXTURE}, type = .TRANSPARENT, albedo_handle = tex) or_continue
    sprite := render.create_sprite(&engine.render, tex, 6, 17) or_continue
    node, ok := mjolnir.spawn(engine, {x, 1.5, 0}, render.SpriteAttachment {
      sprite_handle = sprite,
      mesh_handle   = render.get_builtin_mesh(&engine.render, .QUAD_XY),
      material      = mat,
    })
    if !ok {
      render.destroy_sprite(&engine.render, sprite)
      continue
    }
    sprites[mode] = sprite
    world.scale(&engine.world, node, 2.5)
  }

  mjolnir.spawn(engine, {2, 6, 4}, render.directional_light_attachment(color = {1, 1, 1, 1}, radius = 8))
}

// Pick each sprite's sheet cell from elapsed time.
update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  elapsed += dt
  step := u32(elapsed * FPS)
  cycle := u32(2 * (FRAME_COUNT - 1))
  bounce := step % cycle
  frames := [Mode]u32 {
    .LOOP     = step % FRAME_COUNT,
    .PINGPONG = bounce if bounce < FRAME_COUNT else cycle - bounce,
    .ONCE     = min(step, FRAME_COUNT - 1),
  }
  for sprite, mode in sprites do render.set_sprite_frame(&engine.render, sprite, frames[mode])
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}
