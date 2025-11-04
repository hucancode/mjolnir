package animation

import "core:math"
import "core:math/linalg"
import "core:slice"

InterpolationMode :: enum {
  LINEAR,
  STEP,
  CUBICSPLINE,
}

Keyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

CubicSplineKeyframe :: struct($T: typeid) {
  time:        f32,
  in_tangent:  T,
  value:       T,
  out_tangent: T,
}

keyframe_sample_or :: proc {
  keyframe_sample_or_linear,
  keyframe_sample_or_step,
  keyframe_sample_or_cubic,
}

keyframe_sample_or_linear :: proc(frames: []Keyframe($T), t: f32, fallback: T) -> T {
  return keyframe_sample_linear(frames, t) if len(frames) > 0 else fallback
}

keyframe_sample_or_step :: proc(frames: []Keyframe($T), t: f32, fallback: T) -> T {
  return keyframe_sample_step(frames, t) if len(frames) > 0 else fallback
}

keyframe_sample_or_cubic :: proc(frames: []CubicSplineKeyframe($T), t: f32, fallback: T) -> T {
  return keyframe_sample_cubic(frames, t) if len(frames) > 0 else fallback
}

keyframe_sample :: proc {
  keyframe_sample_linear,
  keyframe_sample_step,
  keyframe_sample_cubic,
}

keyframe_sample_linear :: proc(frames: []Keyframe($T), t: f32) -> T {
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

keyframe_sample_step :: proc(frames: []Keyframe($T), t: f32) -> T {
  if len(frames) == 0 {
    return T{}
  }
  if t <= slice.first(frames).time {
    return slice.first(frames).value
  }
  if t >= slice.last(frames).time {
    return slice.last(frames).value
  }
  // binary search to find the upper bound (first keyframe with time > t)
  cmp :: proc(item: Keyframe(T), t: f32) -> slice.Ordering {
    return slice.Ordering.Less if item.time <= t else slice.Ordering.Greater
  }
  upper_idx, exact_match := slice.binary_search_by(frames, t, cmp)
  if exact_match {
    // t exactly matches a keyframe time
    return frames[upper_idx].value
  } else {
    // t is between keyframes, return the previous keyframe's value
    return frames[upper_idx - 1].value
  }
}

keyframe_sample_cubic :: proc(frames: []CubicSplineKeyframe($T), t: f32) -> T {
  if len(frames) == 0 {
    return T{}
  }
  if t <= slice.first(frames).time {
    return slice.first(frames).value
  }
  if t >= slice.last(frames).time {
    return slice.last(frames).value
  }
  cmp :: proc(item: CubicSplineKeyframe(T), t: f32) -> slice.Ordering {
    return slice.Ordering.Less if item.time < t else slice.Ordering.Greater
  }
  i, _ := slice.binary_search_by(frames, t, cmp)
  a := frames[i - 1]
  b := frames[i]
  dt := b.time - a.time
  u := (t - a.time) / dt
  u2 := u * u
  u3 := u2 * u
  h00 := 2*u3 - 3*u2 + 1
  h10 := u3 - 2*u2 + u
  h01 := -2*u3 + 3*u2
  h11 := u3 - u2
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    q0 := a.value
    m0_scaled := quaternion(
      x = a.out_tangent.x * dt,
      y = a.out_tangent.y * dt,
      z = a.out_tangent.z * dt,
      w = a.out_tangent.w * dt,
    )
    q1 := b.value
    m1_scaled := quaternion(
      x = b.in_tangent.x * dt,
      y = b.in_tangent.y * dt,
      z = b.in_tangent.z * dt,
      w = b.in_tangent.w * dt,
    )
    result_x := h00 * q0.x + h10 * m0_scaled.x + h01 * q1.x + h11 * m1_scaled.x
    result_y := h00 * q0.y + h10 * m0_scaled.y + h01 * q1.y + h11 * m1_scaled.y
    result_z := h00 * q0.z + h10 * m0_scaled.z + h01 * q1.z + h11 * m1_scaled.z
    result_w := h00 * q0.w + h10 * m0_scaled.w + h01 * q1.w + h11 * m1_scaled.w
    result := linalg.quaternion_normalize(quaternion(
      x = result_x,
      y = result_y,
      z = result_z,
      w = result_w,
    ))
    return result
  } else {
    return h00 * a.value + h10 * (a.out_tangent * dt) + h01 * b.value + h11 * (b.in_tangent * dt)
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
  clip:     ^Clip,
  mode:     PlayMode,
  status:   Status,
  time:     f32,
  duration: f32,
  speed:    f32,
}

instance_init :: proc(self: ^Instance, clip: ^Clip) {
  self.clip = clip
  self.mode = .LOOP
  self.status = .STOPPED
  self.time = 0.0
  self.duration = clip.duration if clip != nil else 0.0
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
  position_interpolation: InterpolationMode,
  rotation_interpolation: InterpolationMode,
  scale_interpolation:    InterpolationMode,
  positions:         []Keyframe([3]f32),
  rotations:         []Keyframe(quaternion128),
  scales:            []Keyframe([3]f32),
  cubic_positions:   []CubicSplineKeyframe([3]f32),
  cubic_rotations:   []CubicSplineKeyframe(quaternion128),
  cubic_scales:      []CubicSplineKeyframe([3]f32),
}

channel_destroy :: proc(channel: ^Channel) {
  delete(channel.positions)
  channel.positions = nil
  delete(channel.rotations)
  channel.rotations = nil
  delete(channel.scales)
  channel.scales = nil
  delete(channel.cubic_positions)
  channel.cubic_positions = nil
  delete(channel.cubic_rotations)
  channel.cubic_rotations = nil
  delete(channel.cubic_scales)
  channel.cubic_scales = nil
}

// Sample channel, returning Maybe for each component (nil if no keyframe data)
// Use this for node animations where you want to preserve non-animated components
channel_sample_some :: proc(
  channel: Channel,
  t: f32,
) -> (
  position: Maybe([3]f32),
  rotation: Maybe(quaternion128),
  scale: Maybe([3]f32),
) {
  // Only return a value if the channel has keyframe data
  if len(channel.positions) > 0 || len(channel.cubic_positions) > 0 {
    pos_value: [3]f32
    switch channel.position_interpolation {
    case .LINEAR:
      pos_value = keyframe_sample_linear(channel.positions, t)
    case .STEP:
      pos_value = keyframe_sample_step(channel.positions, t)
    case .CUBICSPLINE:
      pos_value = keyframe_sample_cubic(channel.cubic_positions, t)
    }
    position = pos_value
  }

  if len(channel.rotations) > 0 || len(channel.cubic_rotations) > 0 {
    rot_value: quaternion128
    switch channel.rotation_interpolation {
    case .LINEAR:
      rot_value = keyframe_sample_or_linear(
        channel.rotations,
        t,
        linalg.QUATERNIONF32_IDENTITY,
      )
    case .STEP:
      rot_value = keyframe_sample_or_step(
        channel.rotations,
        t,
        linalg.QUATERNIONF32_IDENTITY,
      )
    case .CUBICSPLINE:
      rot_value = keyframe_sample_or_cubic(
        channel.cubic_rotations,
        t,
        linalg.QUATERNIONF32_IDENTITY,
      )
    }
    rotation = rot_value
  }

  if len(channel.scales) > 0 || len(channel.cubic_scales) > 0 {
    scale_value: [3]f32
    switch channel.scale_interpolation {
    case .LINEAR:
      scale_value = keyframe_sample_or_linear(channel.scales, t, [3]f32{1, 1, 1})
    case .STEP:
      scale_value = keyframe_sample_or_step(channel.scales, t, [3]f32{1, 1, 1})
    case .CUBICSPLINE:
      scale_value = keyframe_sample_or_cubic(channel.cubic_scales, t, [3]f32{1, 1, 1})
    }
    scale = scale_value
  }

  return
}

// Sample channel, always returning all components with defaults if no keyframe data
// Use this for skeletal animations where every bone needs a complete transform
channel_sample_all :: proc(
  channel: Channel,
  t: f32,
) -> (
  position: [3]f32,
  rotation: quaternion128,
  scale: [3]f32,
) {
  maybe_pos, maybe_rot, maybe_scl := channel_sample_some(channel, t)
  position = maybe_pos.? or_else [3]f32{0, 0, 0}
  rotation = maybe_rot.? or_else linalg.QUATERNIONF32_IDENTITY
  scale = maybe_scl.? or_else [3]f32{1, 1, 1}
  return
}

Clip :: struct {
  name:     string,
  duration: f32,
  channels: []Channel,
}

clip_destroy :: proc(clip: ^Clip) {
  for &channel in clip.channels do channel_destroy(&channel)
  delete(clip.channels)
  clip.channels = nil
}

FKLayer :: struct {
  clip_handle: u64,      // Handle to animation clip (stores resources.Handle as u64)
  mode:        PlayMode,
  status:      Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

IKLayer :: struct {
  target: IKTarget, // IK constraint
}

LayerData :: union {
  FKLayer,
  IKLayer,
}

Layer :: struct {
  weight: f32,       // Blend weight (0.0 to 1.0)
  data:   LayerData, // FK or IK layer data
}

layer_init_fk :: proc(self: ^Layer, clip_handle: u64, duration: f32, weight: f32 = 1.0, mode: PlayMode = .LOOP, speed: f32 = 1.0) {
  self.weight = weight
  self.data = FKLayer {
    clip_handle = clip_handle,
    mode        = mode,
    status      = .PLAYING,
    time        = 0.0,
    duration    = duration,
    speed       = speed,
  }
}

layer_init_ik :: proc(self: ^Layer, target: IKTarget, weight: f32 = 1.0) {
  self.weight = weight
  self.data = IKLayer{target = target}
}

layer_update :: proc(self: ^Layer, delta_time: f32) {
  switch &layer_data in self.data {
  case FKLayer:
    // Update FK layer time
    if layer_data.status != .PLAYING || layer_data.duration <= 0 {
      return
    }
    effective_delta_time := delta_time * layer_data.speed
    switch layer_data.mode {
    case .LOOP:
      layer_data.time += effective_delta_time
      layer_data.time = math.mod_f32(layer_data.time + layer_data.duration, layer_data.duration)
    case .ONCE:
      layer_data.time += effective_delta_time
      layer_data.time = math.mod_f32(layer_data.time + layer_data.duration, layer_data.duration)
      if layer_data.time >= layer_data.duration {
        layer_data.time = layer_data.duration
        layer_data.status = .STOPPED
      }
    case .PING_PONG:
      layer_data.time += effective_delta_time
      if layer_data.time >= layer_data.duration || layer_data.time < 0 {
        layer_data.speed *= -1
      }
    }
  case IKLayer:
    // IK doesn't have time-based updates
  }
}
