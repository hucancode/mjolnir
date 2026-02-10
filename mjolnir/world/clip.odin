package world

import "../animation"
import cont "../containers"
import d "../data"

create_animation_clip :: proc(
  world: ^World,
  channel_count: int,
  duration: f32 = 1.0,
  name: string = "",
) -> (
  handle: d.ClipHandle,
  ok: bool,
) #optional_ok {
  h, clip := cont.alloc(&world.animation_clips, d.ClipHandle) or_return
  clip^ = animation.clip_create(
    channel_count = channel_count,
    duration = duration,
    name = name,
  )
  return h, true
}
