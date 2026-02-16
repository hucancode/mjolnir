package animation

import "core:math"
import "core:math/ease"
import "core:math/linalg"

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

BlendMode :: enum {
  REPLACE,   // Default: weighted blend (current behavior)
  ADD,       // Add transforms on top of accumulated (additive blending)
  MULTIPLY,  // Multiply scales (position ignored, rotation composed)
  OVERRIDE,  // Completely replace accumulated (weight acts as 0/1 gate)
}

TransitionState :: enum {
  NONE,     // No transition active
  ACTIVE,   // Transition in progress
  COMPLETE, // Transition finished
}

Transition :: struct {
  from_layer: int,  // Source layer index
  to_layer:   int,  // Target layer index
  duration:   f32,  // Total transition time
  elapsed:    f32,  // Time elapsed
  curve:      ease.Ease, // Easing curve
  state:      TransitionState,
}

// Blend position based on mode
blend_position :: proc(
  accumulated: [3]f32,
  new_value: [3]f32,
  weight: f32,
  mode: BlendMode,
) -> [3]f32 {
  switch mode {
  case .REPLACE:
    // Default weighted accumulation
    return accumulated + new_value * weight
  case .ADD:
    // Additive blending: add on top of accumulated
    return accumulated + new_value * weight
  case .MULTIPLY:
    // Position ignored for multiply mode
    return accumulated
  case .OVERRIDE:
    // Hard switch based on weight threshold
    return new_value if weight > 0.5 else accumulated
  }
  return accumulated
}

// Blend rotation based on mode
blend_rotation :: proc(
  accumulated: quaternion128,
  accumulated_weight: f32,
  new_value: quaternion128,
  weight: f32,
  mode: BlendMode,
) -> quaternion128 {
  switch mode {
  case .REPLACE:
    // Default SLERP accumulation
    if accumulated_weight > 0 {
      return linalg.quaternion_slerp(
        accumulated,
        new_value,
        weight / (accumulated_weight + weight),
      )
    }
    return new_value
  case .ADD:
    // Additive blending: multiply quaternions
    return linalg.quaternion_mul_quaternion(accumulated, new_value)
  case .MULTIPLY:
    // Same as ADD for rotations
    return linalg.quaternion_mul_quaternion(accumulated, new_value)
  case .OVERRIDE:
    // Hard switch based on weight threshold
    return new_value if weight > 0.5 else accumulated
  }
  return accumulated
}

// Blend scale based on mode
blend_scale :: proc(
  accumulated: [3]f32,
  new_value: [3]f32,
  weight: f32,
  mode: BlendMode,
) -> [3]f32 {
  switch mode {
  case .REPLACE:
    // Default weighted accumulation
    return accumulated + new_value * weight
  case .ADD:
    // Additive blending
    return accumulated + new_value * weight
  case .MULTIPLY:
    // Multiplicative blending
    return accumulated * (1 + (new_value - 1) * weight)
  case .OVERRIDE:
    // Hard switch based on weight threshold
    return new_value if weight > 0.5 else accumulated
  }
  return accumulated
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
  ProceduralLayer,
}

Layer :: struct {
  weight:     f32,            // Blend weight (0.0 to 1.0)
  blend_mode: BlendMode,      // Blending mode for this layer
  bone_mask:  Maybe([]bool),  // nil = affect all bones, []bool = per-bone enable
  data:       LayerData,      // FK or IK layer data
}

layer_init_fk :: proc(
  self: ^Layer,
  clip_handle: u64,
  duration: f32,
  weight: f32 = 1.0,
  mode: PlayMode = .LOOP,
  speed: f32 = 1.0,
  blend_mode: BlendMode = .REPLACE,
) {
  self.weight = weight
  self.blend_mode = blend_mode
  self.data = FKLayer {
    clip_handle = clip_handle,
    mode        = mode,
    status      = .PLAYING,
    time        = 0.0,
    duration    = duration,
    speed       = speed,
  }
}

layer_init_ik :: proc(
  self: ^Layer,
  target: IKTarget,
  weight: f32 = 1.0,
  blend_mode: BlendMode = .REPLACE,
) {
  self.weight = weight
  self.blend_mode = blend_mode
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
  case ProceduralLayer:
  // Procedural modifiers update time during sampling
  }
}
