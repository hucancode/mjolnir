package resources

import "../gpu"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

MAX_SPRITES :: 4096

SpriteAnimationState :: enum {
  PLAYING,
  PAUSED,
  STOPPED,
}

SpriteAnimation :: struct {
  frame_count:   u32,
  current_frame: u32,
  fps:           f32,
  time:          f32,
  state:         SpriteAnimationState,
  loop:          bool,
}

SpriteData :: struct {
  texture_index: u32,
  sampler_type:  SamplerType,
  frame_columns: u32, // Number of columns in sprite sheet
  frame_rows:    u32, // Number of rows in sprite sheet
  frame_index:   u32, // Current frame (0-based)
  _padding:      [3]u32, // Align to 16 bytes
  color:         [4]f32,
  // Total: 48 bytes (16 + 16 + 16)
}

Sprite :: struct {
  using data: SpriteData,
  animation:  Maybe(SpriteAnimation),
}

sprite_animation_init :: proc(
  frame_count: u32,
  fps: f32 = 12.0,
  loop: bool = true,
) -> SpriteAnimation {
  return SpriteAnimation {
    frame_count = frame_count,
    current_frame = 0,
    fps = fps,
    time = 0.0,
    state = .PLAYING,
    loop = loop,
  }
}

sprite_animation_update :: proc(anim: ^SpriteAnimation, delta_time: f32) {
  if anim.state != .PLAYING do return
  if anim.frame_count <= 1 do return
  if anim.fps <= 0 do return
  if delta_time <= 0 || delta_time > 1.0 do return

  anim.time += delta_time
  frame_duration := 1.0 / anim.fps

  // Limit iterations to prevent infinite loops from large delta_time
  max_iterations := anim.frame_count * 2
  iteration := u32(0)

  for anim.time >= frame_duration {
    if iteration >= max_iterations {
      // Skip ahead instead of looping thousands of times
      frames_to_skip := u32(anim.time / frame_duration)
      anim.time = math.mod(anim.time, frame_duration)
      if anim.loop {
        anim.current_frame = frames_to_skip % anim.frame_count
      } else {
        anim.current_frame = min(frames_to_skip, anim.frame_count - 1)
        anim.state = .STOPPED
      }
      break
    }

    anim.time -= frame_duration
    anim.current_frame += 1

    if anim.current_frame >= anim.frame_count {
      if anim.loop {
        anim.current_frame = 0
      } else {
        anim.current_frame = anim.frame_count - 1
        anim.state = .STOPPED
        break
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
  anim.current_frame = 0
  anim.time = 0.0
}

sprite_animation_set_frame :: proc(anim: ^SpriteAnimation, frame: u32) {
  anim.current_frame = min(frame, anim.frame_count - 1)
}

sprite_init :: proc(
  self: ^Sprite,
  texture: Handle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  frame_index: u32 = 0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  sampler: SamplerType = .NEAREST_REPEAT,
) {
  self.texture_index = texture.index
  self.sampler_type = sampler
  self.frame_columns = frame_columns
  self.frame_rows = frame_rows
  self.frame_index = frame_index
  self.color = color
}

sprite_update_gpu_data :: proc(sprite: ^Sprite) {
  if anim, has_anim := &sprite.animation.?; has_anim {
    sprite.frame_index = anim.current_frame
  }
}

sprite_write_to_gpu :: proc(
  manager: ^Manager,
  handle: Handle,
  sprite: ^Sprite,
) -> vk.Result {
  if handle.index >= MAX_SPRITES {
    log.errorf(
      "Sprite index %d exceeds capacity %d",
      handle.index,
      MAX_SPRITES,
    )
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  sprite_update_gpu_data(sprite)
  return gpu.write(&manager.sprite_buffer, &sprite.data, int(handle.index))
}

create_sprite :: proc(
  manager: ^Manager,
  texture: Handle,
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  frame_index: u32 = 0,
  color: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  sampler: SamplerType = .NEAREST_REPEAT,
  animation: Maybe(SpriteAnimation) = nil,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  sprite: ^Sprite
  handle, sprite, ok = alloc(&manager.sprites)
  if !ok {
    log.error("Failed to allocate sprite: pool capacity reached")
    return {}, false
  }

  sprite_init(
    sprite,
    texture,
    frame_columns,
    frame_rows,
    frame_index,
    color,
    sampler,
  )
  sprite.animation = animation

  res := sprite_write_to_gpu(manager, handle, sprite)
  if res != .SUCCESS {
    free(&manager.sprites, handle)
    return {}, false
  }
  return handle, true
}

destroy_sprite_handle :: proc(manager: ^Manager, handle: Handle) {
  free(&manager.sprites, handle)
}
