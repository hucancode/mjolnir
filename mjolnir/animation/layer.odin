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

// Advance playback time by delta_time according to mode.
// ONCE clamps at duration and stops; PING_PONG flips speed at either end.
playback_advance :: proc(
  time, speed: ^f32,
  status: ^Status,
  mode: PlayMode,
  duration, delta_time: f32,
) {
  if status^ != .PLAYING || duration <= 0 do return
  time^ += delta_time * speed^
  switch mode {
  case .LOOP:
    time^ = math.mod_f32(time^ + duration, duration)
  case .ONCE:
    if time^ >= duration {
      time^ = duration
      status^ = .STOPPED
    }
  case .PING_PONG:
    if time^ >= duration || time^ < 0 do speed^ *= -1
  }
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

// Advance a transition and cross-fade the two layer weights. Sets state to
// COMPLETE on the tick it finishes (from = 0, to = 1).
transition_update :: proc(self: ^Transition, layers: []Layer, delta_time: f32) {
  if self.state != .ACTIVE do return
  if self.from_layer >= len(layers) || self.to_layer >= len(layers) {
    self.state = .NONE
    return
  }
  self.elapsed += delta_time
  t: f32 = 1
  if self.duration > 0 && self.elapsed < self.duration {
    t = ease.ease(self.curve, self.elapsed / self.duration)
  } else {
    self.elapsed = self.duration
    self.state = .COMPLETE
  }
  layers[self.from_layer].weight = 1 - t
  layers[self.to_layer].weight = t
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

// Plays one clip of the rig (index into Rig.clips).
FKLayer :: struct {
  clip:   int,
  mode:   PlayMode,
  status: Status,
  time:   f32,
  speed:  f32,
}

LayerData :: union {
  FKLayer,
  IKTarget,
  ProceduralLayer,
}

Layer :: struct {
  weight:     f32,           // Blend weight (0.0 to 1.0)
  blend_mode: BlendMode,
  bone_mask:  Maybe([]bool), // nil = all bones; owned by the caller
  data:       LayerData,
}
