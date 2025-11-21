package resources

import "../animation"
import cont "../containers"

create_animation_clip :: proc(
  self: ^Manager,
  channel_count: int,
  duration: f32 = 1.0,
  name: string = "",
) -> (
  handle: ClipHandle,
  ok: bool,
) #optional_ok {
  h, clip := cont.alloc(&self.animation_clips, ClipHandle) or_return
  clip^ = animation.clip_create(
    channel_count = channel_count,
    duration = duration,
    name = name,
  )
  return h, true
}
