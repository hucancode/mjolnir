package animation

import "core:math"
import "core:math/linalg"
import "core:slice"

InterpolationMode :: enum {
  LINEAR,
  STEP,
  CUBICSPLINE,
}

LinearKeyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

StepKeyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

CubicSplineKeyframe :: struct($T: typeid) {
  time:        f32,
  in_tangent:  T,
  value:       T,
  out_tangent: T,
}

Keyframe :: union($T: typeid) {
  LinearKeyframe(T),
  StepKeyframe(T),
  CubicSplineKeyframe(T),
}

// Helper to get time from any keyframe variant
keyframe_time :: proc(kf: Keyframe($T)) -> f32 {
  switch v in kf {
  case LinearKeyframe(T):
    return v.time
  case StepKeyframe(T):
    return v.time
  case CubicSplineKeyframe(T):
    return v.time
  }
  return 0
}

// Helper to get value from any keyframe variant
keyframe_value :: proc(kf: Keyframe($T)) -> T {
  switch v in kf {
  case LinearKeyframe(T):
    return v.value
  case StepKeyframe(T):
    return v.value
  case CubicSplineKeyframe(T):
    return v.value
  }
  return T{}
}

// 9 interpolation helpers for all combinations
sample_linear_linear :: proc(
  a: LinearKeyframe($T),
  b: LinearKeyframe(T),
  t: f32,
) -> T {
  alpha := (t - a.time) / (b.time - a.time)
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    return linalg.quaternion_slerp(a.value, b.value, alpha)
  } else {
    return linalg.lerp(a.value, b.value, alpha)
  }
}

sample_linear_step :: proc(
  a: LinearKeyframe($T),
  b: StepKeyframe(T),
  t: f32,
) -> T {
  return a.value
}

sample_linear_cubic :: proc(
  a: LinearKeyframe($T),
  b: CubicSplineKeyframe(T),
  t: f32,
) -> T {
  dt := b.time - a.time
  u := (t - a.time) / dt
  u2 := u * u
  u3 := u2 * u
  h00 := 2 * u3 - 3 * u2 + 1
  h01 := -2 * u3 + 3 * u2
  h11 := u3 - u2
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    q0 := a.value
    q1 := b.value
    m1_scaled := quaternion(
      x = b.in_tangent.x * dt,
      y = b.in_tangent.y * dt,
      z = b.in_tangent.z * dt,
      w = b.in_tangent.w * dt,
    )
    result_x := h00 * q0.x + h01 * q1.x + h11 * m1_scaled.x
    result_y := h00 * q0.y + h01 * q1.y + h11 * m1_scaled.y
    result_z := h00 * q0.z + h01 * q1.z + h11 * m1_scaled.z
    result_w := h00 * q0.w + h01 * q1.w + h11 * m1_scaled.w
    return linalg.normalize(
      quaternion(x = result_x, y = result_y, z = result_z, w = result_w),
    )
  } else {
    return h00 * a.value + h01 * b.value + h11 * (b.in_tangent * dt)
  }
}

sample_step_linear :: proc(
  a: StepKeyframe($T),
  b: LinearKeyframe(T),
  t: f32,
) -> T {
  // Step holds value until we reach the next keyframe's exact time
  if t >= b.time {
    return b.value
  }
  return a.value
}

sample_step_step :: proc(
  a: StepKeyframe($T),
  b: StepKeyframe(T),
  t: f32,
) -> T {
  // Step holds value until we reach the next keyframe's exact time
  if t >= b.time {
    return b.value
  }
  return a.value
}

sample_step_cubic :: proc(
  a: StepKeyframe($T),
  b: CubicSplineKeyframe(T),
  t: f32,
) -> T {
  // Step holds value until we reach the next keyframe's exact time
  if t >= b.time {
    return b.value
  }
  return a.value
}

sample_cubic_linear :: proc(
  a: CubicSplineKeyframe($T),
  b: LinearKeyframe(T),
  t: f32,
) -> T {
  dt := b.time - a.time
  u := (t - a.time) / dt
  u2 := u * u
  u3 := u2 * u
  h00 := 2 * u3 - 3 * u2 + 1
  h10 := u3 - 2 * u2 + u
  h01 := -2 * u3 + 3 * u2
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    q0 := a.value
    m0_scaled := quaternion(
      x = a.out_tangent.x * dt,
      y = a.out_tangent.y * dt,
      z = a.out_tangent.z * dt,
      w = a.out_tangent.w * dt,
    )
    q1 := b.value
    result_x := h00 * q0.x + h10 * m0_scaled.x + h01 * q1.x
    result_y := h00 * q0.y + h10 * m0_scaled.y + h01 * q1.y
    result_z := h00 * q0.z + h10 * m0_scaled.z + h01 * q1.z
    result_w := h00 * q0.w + h10 * m0_scaled.w + h01 * q1.w
    return linalg.normalize(
      quaternion(x = result_x, y = result_y, z = result_z, w = result_w),
    )
  } else {
    return h00 * a.value + h10 * (a.out_tangent * dt) + h01 * b.value
  }
}

sample_cubic_step :: proc(
  a: CubicSplineKeyframe($T),
  b: StepKeyframe(T),
  t: f32,
) -> T {
  return a.value
}

sample_cubic_cubic :: proc(
  a: CubicSplineKeyframe($T),
  b: CubicSplineKeyframe(T),
  t: f32,
) -> T {
  dt := b.time - a.time
  u := (t - a.time) / dt
  u2 := u * u
  u3 := u2 * u
  h00 := 2 * u3 - 3 * u2 + 1
  h10 := u3 - 2 * u2 + u
  h01 := -2 * u3 + 3 * u2
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
    return linalg.normalize(
      quaternion(x = result_x, y = result_y, z = result_z, w = result_w),
    )
  } else {
    return(
      h00 * a.value +
      h10 * (a.out_tangent * dt) +
      h01 * b.value +
      h11 * (b.in_tangent * dt) \
    )
  }
}

keyframe_sample :: proc(frames: []Keyframe($T), t: f32, fallback: T) -> T {
  if len(frames) == 0 {
    return fallback
  }

  first_time := keyframe_time(slice.first(frames))
  last_time := keyframe_time(slice.last(frames))

  if t <= first_time {
    return keyframe_value(slice.first(frames))
  }

  if t >= last_time {
    return keyframe_value(slice.last(frames))
  }

  cmp :: proc(item: Keyframe(T), t: f32) -> slice.Ordering {
    item_time := keyframe_time(item)
    return slice.Ordering.Less if item_time < t else slice.Ordering.Greater
  }
  i, _ := slice.binary_search_by(frames, t, cmp)

  a := frames[i - 1]
  b := frames[i]
  switch a_variant in a {
  case LinearKeyframe(T):
    switch b_variant in b {
    case LinearKeyframe(T):
      return sample_linear_linear(a_variant, b_variant, t)
    case StepKeyframe(T):
      return sample_linear_step(a_variant, b_variant, t)
    case CubicSplineKeyframe(T):
      return sample_linear_cubic(a_variant, b_variant, t)
    }
  case StepKeyframe(T):
    switch b_variant in b {
    case LinearKeyframe(T):
      return sample_step_linear(a_variant, b_variant, t)
    case StepKeyframe(T):
      return sample_step_step(a_variant, b_variant, t)
    case CubicSplineKeyframe(T):
      return sample_step_cubic(a_variant, b_variant, t)
    }
  case CubicSplineKeyframe(T):
    switch b_variant in b {
    case LinearKeyframe(T):
      return sample_cubic_linear(a_variant, b_variant, t)
    case StepKeyframe(T):
      return sample_cubic_step(a_variant, b_variant, t)
    case CubicSplineKeyframe(T):
      return sample_cubic_cubic(a_variant, b_variant, t)
    }
  }

  return fallback
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
  case .ONCE:
    self.time += effective_delta_time
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

channel_init :: proc(
  channel: ^Channel,
  position_count: int = 0,
  rotation_count: int = 0,
  scale_count: int = 0,
  position_interpolation: InterpolationMode = .LINEAR,
  rotation_interpolation: InterpolationMode = .LINEAR,
  scale_interpolation: InterpolationMode = .LINEAR,
  duration: f32 = 1.0,
) {
  if position_count > 0 {
    channel.positions = make([]Keyframe([3]f32), position_count)
    for &kf, i in channel.positions {
      time :=
        f32(i) * duration / f32(position_count - 1) if position_count > 1 else 0
      switch position_interpolation {
      case .LINEAR:
        kf = LinearKeyframe([3]f32) {
          time  = time,
          value = [3]f32{0, 0, 0},
        }
      case .STEP:
        kf = StepKeyframe([3]f32) {
          time  = time,
          value = [3]f32{0, 0, 0},
        }
      case .CUBICSPLINE:
        kf = CubicSplineKeyframe([3]f32) {
          time        = time,
          value       = [3]f32{0, 0, 0},
          in_tangent  = [3]f32{0, 0, 0},
          out_tangent = [3]f32{0, 0, 0},
        }
      }
    }
  }
  if rotation_count > 0 {
    channel.rotations = make([]Keyframe(quaternion128), rotation_count)
    for &kf, i in channel.rotations {
      time :=
        f32(i) * duration / f32(rotation_count - 1) if rotation_count > 1 else 0
      switch rotation_interpolation {
      case .LINEAR:
        kf = LinearKeyframe(quaternion128) {
          time  = time,
          value = linalg.QUATERNIONF32_IDENTITY,
        }
      case .STEP:
        kf = StepKeyframe(quaternion128) {
          time  = time,
          value = linalg.QUATERNIONF32_IDENTITY,
        }
      case .CUBICSPLINE:
        kf = CubicSplineKeyframe(quaternion128) {
          time        = time,
          value       = linalg.QUATERNIONF32_IDENTITY,
          in_tangent  = linalg.QUATERNIONF32_IDENTITY,
          out_tangent = linalg.QUATERNIONF32_IDENTITY,
        }
      }
    }
  }
  if scale_count > 0 {
    channel.scales = make([]Keyframe([3]f32), scale_count)
    for &kf, i in channel.scales {
      time :=
        f32(i) * duration / f32(scale_count - 1) if scale_count > 1 else 0
      switch scale_interpolation {
      case .LINEAR:
        kf = LinearKeyframe([3]f32) {
          time  = time,
          value = [3]f32{1, 1, 1},
        }
      case .STEP:
        kf = StepKeyframe([3]f32) {
          time  = time,
          value = [3]f32{1, 1, 1},
        }
      case .CUBICSPLINE:
        kf = CubicSplineKeyframe([3]f32) {
          time        = time,
          value       = [3]f32{1, 1, 1},
          in_tangent  = [3]f32{0, 0, 0},
          out_tangent = [3]f32{0, 0, 0},
        }
      }
    }
  }
}

channel_destroy :: proc(channel: ^Channel) {
  delete(channel.positions)
  channel.positions = nil
  delete(channel.rotations)
  channel.rotations = nil
  delete(channel.scales)
  channel.scales = nil
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
  if len(channel.positions) > 0 {
    position = keyframe_sample(channel.positions, t, [3]f32{0, 0, 0})
  }

  if len(channel.rotations) > 0 {
    rotation = keyframe_sample(
      channel.rotations,
      t,
      linalg.QUATERNIONF32_IDENTITY,
    )
  }

  if len(channel.scales) > 0 {
    scale = keyframe_sample(channel.scales, t, [3]f32{1, 1, 1})
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

clip_create :: proc(
  channel_count: int,
  duration: f32 = 1.0,
  name: string = "",
) -> Clip {
  clip := Clip {
    name     = name,
    duration = duration,
    channels = make([]Channel, channel_count),
  }
  return clip
}

clip_destroy :: proc(clip: ^Clip) {
  for &channel in clip.channels do channel_destroy(&channel)
  delete(clip.channels)
  clip.channels = nil
}

FKLayer :: struct {
  clip_handle: u64, // Handle to animation clip (stores resources.Handle as u64)
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
  weight: f32, // Blend weight (0.0 to 1.0)
  data:   LayerData, // FK or IK layer data
}

layer_init_fk :: proc(
  self: ^Layer,
  clip_handle: u64,
  duration: f32,
  weight: f32 = 1.0,
  mode: PlayMode = .LOOP,
  speed: f32 = 1.0,
) {
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
  self.data = IKLayer {
    target = target,
  }
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
      layer_data.time = math.mod_f32(
        layer_data.time + layer_data.duration,
        layer_data.duration,
      )
    case .ONCE:
      layer_data.time += effective_delta_time
      layer_data.time = math.mod_f32(
        layer_data.time + layer_data.duration,
        layer_data.duration,
      )
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
