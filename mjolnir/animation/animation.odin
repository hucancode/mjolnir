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
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
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

instance_init :: proc(self: ^Instance, clip: u32) {
  self.clip_handle = clip
  self.mode = .LOOP
  self.status = .STOPPED
  self.time = 0.0
  self.speed = 1.0
}

instance_pause :: proc(self: ^Instance) {
  self.status = .PAUSED
}

instance_play :: proc(self: ^Instance) {
  self.status = .PLAYING
}

instance_toggle :: proc(self: ^Instance) {
  switch self.status {
  case .PLAYING:
    instance_pause(self)
  case .PAUSED:
    instance_play(self)
  case .STOPPED:
    self.time = 0
    instance_play(self)
  }
}

instance_stop :: proc(self: ^Instance) {
  self.status = .STOPPED
  self.time = 0
}

instance_update :: proc(self: ^Instance, delta_time: f32) {
  if self.status != .PLAYING || self.duration <= 0 {
    return
  }
  effective_delta_time := delta_time * self.speed
  switch self.mode {
  case .LOOP:
    self.time += effective_delta_time
    self.time = math.mod_f32(self.time + self.duration, self.duration)
  // log.infof("animation_instance_update: time +%f = %f", effective_delta_time, self.time)
  case .ONCE:
    self.time += effective_delta_time
    self.time = math.mod_f32(self.time + self.duration, self.duration)
    if self.time >= self.duration {
      self.time = self.duration
      self.status = .STOPPED
    }
  case .PING_PONG:
    self.time += effective_delta_time
    if self.time >= self.duration || self.time < 0 {
      self.speed *= -1
    }
  }
}

Channel :: struct {
  positions: []Keyframe([3]f32),
  rotations: []Keyframe(quaternion128),
  scales:    []Keyframe([3]f32),
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
  position: [3]f32,
  rotation: quaternion128,
  scale: [3]f32,
) {
  position = keyframe_sample(channel.positions, t)
  rotation = keyframe_sample_or(
    channel.rotations,
    t,
    linalg.QUATERNIONF32_IDENTITY,
  )
  scale = keyframe_sample_or(channel.scales, t, [3]f32{1, 1, 1})
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
