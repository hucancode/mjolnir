package world

import cont "../containers"
import d "../data"
import "core:log"
import "core:slice"

MAX_SPRITES :: d.MAX_SPRITES

SpriteAnimationState :: d.SpriteAnimationState
SpriteAnimationMode :: d.SpriteAnimationMode
SpriteAnimation :: d.SpriteAnimation
SpriteData :: d.SpriteData
Sprite :: d.Sprite

sprite_animation_init :: d.sprite_animation_init
sprite_animation_update :: d.sprite_animation_update
sprite_animation_play :: d.sprite_animation_play
sprite_animation_pause :: d.sprite_animation_pause
sprite_animation_stop :: d.sprite_animation_stop
sprite_animation_set_frame :: d.sprite_animation_set_frame
sprite_animation_set_mode :: d.sprite_animation_set_mode
sprite_animation_set_direction :: d.sprite_animation_set_direction
sprite_init :: d.sprite_init
sprite_update_gpu_data :: d.sprite_update_gpu_data

create_sprite :: proc(
  world: ^World,
  texture: d.Image2DHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  frame_index: u32 = 0,
  animation: Maybe(SpriteAnimation) = nil,
) -> (
  handle: d.SpriteHandle,
  ok: bool,
  ) #optional_ok {
  sprite: ^Sprite
  handle, sprite = cont.alloc(&world.sprites, d.SpriteHandle) or_return
  if handle.index >= MAX_SPRITES {
    log.errorf(
      "Sprite index %d exceeds capacity %d",
      handle.index,
      MAX_SPRITES,
    )
    cont.free(&world.sprites, handle)
    return {}, false
  }
  sprite_init(
    sprite,
    texture,
    frame_columns,
    frame_rows,
    frame_index,
  )
  sprite.animation = animation
  sprite_update_gpu_data(sprite)
  stage_sprite_data(&world.staging, handle, sprite.data)
  if _, has_anim := animation.?; has_anim {
    register_animatable_sprite(world, handle)
  }
  return handle, true
}

destroy_sprite :: proc(world: ^World, handle: d.SpriteHandle) {
  unregister_animatable_sprite(world, handle)
  cont.free(&world.sprites, handle)
}

register_animatable_sprite :: proc(world: ^World, handle: d.SpriteHandle) {
  if slice.contains(world.animatable_sprites[:], handle) do return
  append(&world.animatable_sprites, handle)
}

unregister_animatable_sprite :: proc(world: ^World, handle: d.SpriteHandle) {
  if i, found := slice.linear_search(world.animatable_sprites[:], handle); found {
    unordered_remove(&world.animatable_sprites, i)
  }
}
