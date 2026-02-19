package world

import cont "../containers"
import "core:log"
import "core:math"
import "core:slice"

Sprite :: struct {
  texture: Image2DHandle,
  frame_columns: u32, // Number of columns in sprite sheet
  frame_rows:    u32, // Number of rows in sprite sheet
  animation:  Maybe(SpriteAnimation),
}

sprite_init :: proc(
  self: ^Sprite,
  texture: Image2DHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
) {
  self.texture = texture
  self.frame_columns = frame_columns
  self.frame_rows = frame_rows
}

create_sprite :: proc(
  world: ^World,
  texture: Image2DHandle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
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
  sprite_init(sprite, texture, frame_columns, frame_rows)
  sprite.animation = animation
  stage_sprite_data(&world.staging, handle)
  return handle, true
}

destroy_sprite :: proc(world: ^World, handle: SpriteHandle) {
  cont.free(&world.sprites, handle)
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
