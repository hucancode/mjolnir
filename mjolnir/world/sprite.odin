package world

import cont "../containers"
import "core:log"
import "core:math"
import "core:slice"

SpriteData :: struct {
	texture_index: u32,
	frame_columns: u32, // Number of columns in sprite sheet
	frame_rows:    u32, // Number of rows in sprite sheet
	frame_index:   u32, // Current frame (0-based)
}
Sprite :: struct {
	using data: SpriteData,
	animation:  Maybe(SpriteAnimation),
}

sprite_init :: proc(
  self: ^Sprite,
  texture: Image2DHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  frame_index: u32 = 0,
) {
  self.texture_index = texture.index
  self.frame_columns = frame_columns
  self.frame_rows = frame_rows
  self.frame_index = frame_index
}

sprite_update_gpu_data :: proc(sprite: ^Sprite) {
  if anim, has_anim := &sprite.animation.?; has_anim {
    sprite.frame_index = anim.current_frame
  }
}

create_sprite :: proc(
  world: ^World,
  texture: Image2DHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  frame_index: u32 = 0,
  animation: Maybe(SpriteAnimation) = nil,
) -> (
  handle: SpriteHandle,
  ok: bool,
  ) #optional_ok {
  sprite: ^Sprite
  handle, sprite = cont.alloc(&world.sprites, SpriteHandle) or_return
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
  stage_sprite_data(&world.staging, handle)
  if _, has_anim := animation.?; has_anim {
    register_animatable_sprite(world, handle)
  }
  return handle, true
}

destroy_sprite :: proc(world: ^World, handle: SpriteHandle) {
  unregister_animatable_sprite(world, handle)
  cont.free(&world.sprites, handle)
}

register_animatable_sprite :: proc(world: ^World, handle: SpriteHandle) {
  if slice.contains(world.animatable_sprites[:], handle) do return
  append(&world.animatable_sprites, handle)
}

unregister_animatable_sprite :: proc(world: ^World, handle: SpriteHandle) {
  if i, found := slice.linear_search(world.animatable_sprites[:], handle); found {
    unordered_remove(&world.animatable_sprites, i)
  }
}

SpriteAnimationState :: enum {
  PLAYING,
  PAUSED,
  STOPPED,
}

SpriteAnimationMode :: enum {
  ONCE,
  LOOP,
  PINGPONG,
}

SpriteAnimation :: struct {
  frame_count:   u32,
  current_frame: u32,
  fps:           f32,
  time:          f32,
  state:         SpriteAnimationState,
  mode:          SpriteAnimationMode,
  forward:       bool,
}

sprite_animation_init :: proc(
  frame_count: u32,
  fps: f32 = 12.0,
  mode: SpriteAnimationMode = .LOOP,
  forward: bool = true,
) -> SpriteAnimation {
  initial_frame := forward ? 0 : frame_count - 1
  return SpriteAnimation {
    frame_count = frame_count,
    current_frame = initial_frame,
    fps = fps,
    time = 0.0,
    state = .PLAYING,
    mode = mode,
    forward = forward,
  }
}

sprite_animation_update :: proc(anim: ^SpriteAnimation, delta_time: f32) {
  if anim.state != .PLAYING do return
  if anim.frame_count <= 1 do return
  if anim.fps <= 0 do return
  if delta_time <= 0 || delta_time > 1.0 do return
  anim.time += delta_time
  frame_duration := 1.0 / anim.fps
  max_iterations := anim.frame_count * 2
  iteration := u32(0)
  for anim.time >= frame_duration {
    if iteration >= max_iterations {
      frames_to_skip := u32(anim.time / frame_duration)
      anim.time = math.mod(anim.time, frame_duration)
      switch anim.mode {
      case .ONCE:
        if anim.forward {
          anim.current_frame = min(frames_to_skip, anim.frame_count - 1)
        } else {
          if frames_to_skip >= anim.frame_count {
            anim.current_frame = 0
          } else {
            anim.current_frame = anim.frame_count - 1 - frames_to_skip
          }
        }
        anim.state = .STOPPED
      case .LOOP:
        if anim.forward {
          anim.current_frame = frames_to_skip % anim.frame_count
        } else {
          anim.current_frame =
            anim.frame_count - 1 - (frames_to_skip % anim.frame_count)
        }
      case .PINGPONG:
        cycle_length := max(1, (anim.frame_count - 1) * 2)
        position := frames_to_skip % cycle_length
        if position < anim.frame_count {
          anim.current_frame = position
          anim.forward = true
        } else {
          anim.current_frame = cycle_length - position
          anim.forward = false
        }
      }
      break
    }
    anim.time -= frame_duration
    if anim.forward {
      anim.current_frame += 1
      if anim.current_frame >= anim.frame_count {
        switch anim.mode {
        case .ONCE:
          anim.current_frame = anim.frame_count - 1
          anim.state = .STOPPED
          break
        case .LOOP:
          anim.current_frame = 0
        case .PINGPONG:
          anim.current_frame = anim.frame_count - 1
          anim.forward = false
        }
      }
    } else {
      if anim.current_frame == 0 {
        switch anim.mode {
        case .ONCE:
          anim.state = .STOPPED
          break
        case .LOOP:
          anim.current_frame = anim.frame_count - 1
        case .PINGPONG:
          anim.forward = true
        }
      } else {
        anim.current_frame -= 1
      }
    }
    iteration += 1
  }
}

sprite_animation_play :: proc(anim: ^SpriteAnimation) {
  anim.state = .PLAYING
}

sprite_animation_pause :: proc(anim: ^SpriteAnimation) {
  anim.state = .PAUSED
}

sprite_animation_stop :: proc(anim: ^SpriteAnimation) {
  anim.state = .STOPPED
  anim.time = 0.0
  anim.current_frame = anim.forward ? 0 : anim.frame_count - 1
}

sprite_animation_set_frame :: proc(anim: ^SpriteAnimation, frame: u32) {
  anim.current_frame = min(frame, anim.frame_count - 1)
}

sprite_animation_set_mode :: proc(
  anim: ^SpriteAnimation,
  mode: SpriteAnimationMode,
) {
  anim.mode = mode
}

sprite_animation_set_direction :: proc(anim: ^SpriteAnimation, forward: bool) {
  anim.forward = forward
  if anim.state == .STOPPED {
    anim.current_frame = forward ? 0 : anim.frame_count - 1
  }
}
