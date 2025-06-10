package animation

import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "core:slice"

Keyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

keyframe_sample_or :: proc(frames: []Keyframe($T), t: f32, fallback: T) -> T {
    return keyframe_sample(frames, t) if len(frames) > 0 else fallback
}

keyframe_sample :: proc(frames: []Keyframe($T), t: f32) -> T {
  if len(frames) == 0 {
      return T{}
  }
  if t <= slice.first(frames).time {
      return slice.first(frames).value
  }
  if t >= slice.last(frames).time {
      return slice.last(frames).value
  }
  cmp :: proc(item: Keyframe(T), t: f32) -> slice.Ordering {
    return slice.Ordering.Less if item.time < t else slice.Ordering.Greater
  }
  i, _ := slice.binary_search_by(frames, t, cmp)
  a := frames[i - 1]
  b := frames[i]
  alpha := (t - a.time) / (b.time - a.time)
  when T == linalg.Quaternionf16 || T == linalg.Quaternionf32 || T == linalg.Quaternionf64 {
    return linalg.quaternion_slerp(a.value, b.value, alpha)
  } else {
    return linalg.lerp(a.value, b.value, alpha)
  }
}

Status :: enum {
  PLAYING,
  PAUSED,
  STOPPED,
}

PlayMode :: enum {
  LOOP,
  ONCE,
  PING_PONG,
}

Instance :: struct {
  clip_handle: u32,
  mode:        PlayMode,
  status:      Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

instance_init :: proc(instance: ^Instance, clip: u32) {
  instance.clip_handle = clip
  instance.mode = .LOOP
  instance.status = .STOPPED
  instance.time = 0.0
  instance.speed = 1.0
}

instance_pause :: proc(instance: ^Instance) {
  instance.status = .PAUSED
}

instance_play :: proc(instance: ^Instance) {
  instance.status = .PLAYING
}

instance_toggle :: proc(instance: ^Instance) {
  switch instance.status {
  case .PLAYING:
    instance_pause(instance)
  case .PAUSED:
    instance_play(instance)
  case .STOPPED:
    instance.time = 0
    instance_play(instance)
  }
}

instance_stop :: proc(instance: ^Instance) {
  instance.status = .STOPPED
  instance.time = 0
}

instance_update :: proc(instance: ^Instance, delta_time: f32) {
  if instance.status != .PLAYING || instance.duration <= 0 {
    return
  }
  effective_delta_time := delta_time * instance.speed
  switch instance.mode {
  case .LOOP:
    instance.time += effective_delta_time
    instance.time = math.mod_f32(
      instance.time + instance.duration,
      instance.duration,
    )
  // log.infof("animation_instance_update: time +%f = %f", effective_delta_time, instance.time)
  case .ONCE:
    instance.time += effective_delta_time
    instance.time = math.mod_f32(
      instance.time + instance.duration,
      instance.duration,
    )
    if instance.time >= instance.duration {
      instance.time = instance.duration
      instance.status = .STOPPED
    }
  case .PING_PONG:
    instance.time += effective_delta_time
    if instance.time >= instance.duration || instance.time < 0 {
      instance.speed *= -1
    }
  }
}

Channel :: struct {
  positions: []Keyframe(linalg.Vector3f32),
  rotations: []Keyframe(linalg.Quaternionf32),
  scales:    []Keyframe(linalg.Vector3f32),
}

channel_deinit :: proc(channel: ^Channel) {
  delete(channel.positions)
  channel.positions = nil
  delete(channel.rotations)
  channel.rotations = nil
  delete(channel.scales)
  channel.scales = nil
}

channel_sample :: proc(
  channel: Channel,
  t: f32,
) -> (
  position: linalg.Vector3f32,
  rotation: linalg.Quaternionf32,
  scale: linalg.Vector3f32,
) {
  position = keyframe_sample(channel.positions, t)
  rotation =
    keyframe_sample_or(channel.rotations, t, linalg.QUATERNIONF32_IDENTITY)
  scale =
    keyframe_sample_or(channel.scales, t, linalg.Vector3f32{1, 1, 1})
  return
}

Clip :: struct {
  name:     string,
  duration: f32,
  channels: []Channel,
}

clip_deinit :: proc(clip: ^Clip) {
  for &channel in clip.channels do channel_deinit(&channel)

  delete(clip.channels)
  clip.channels = nil
}
