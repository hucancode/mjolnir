package animation

import "core:math"
import "core:math/ease"
import "core:math/linalg"

// Status is the playback state of a ClipPlayer.
Status :: enum {
  PLAYING,
  PAUSED,
  STOPPED,
}

// PlayMode selects what a ClipPlayer does when it reaches the end of its clip.
PlayMode :: enum {
  LOOP,
  ONCE,
  PING_PONG,
}

// ClipPlayer is the play head over one clip. A plain value: `ClipPlayer{speed = 1}` loops
// from the start. ONCE clamps at the clip's end and stops; PING_PONG flips
// speed at either end.
ClipPlayer :: struct {
  time:   f32,
  speed:  f32,
  status: Status,
  mode:   PlayMode,
}

@(private)
playback_advance :: proc(self: ^ClipPlayer, duration, delta_time: f32) {
  if self.status != .PLAYING || duration <= 0 do return
  self.time += delta_time * self.speed
  switch self.mode {
  case .LOOP:
    self.time = math.mod_f32(self.time + duration, duration)
  case .ONCE:
    if self.time >= duration {
      self.time = duration
      self.status = .STOPPED
    }
  case .PING_PONG:
    if self.time >= duration || self.time < 0 do self.speed *= -1
  }
}

// BlendMode selects how a layer combines with the layers accumulated before it.
BlendMode :: enum {
  REPLACE,   // Default: weighted blend (current behavior)
  ADD,       // Add transforms on top of accumulated (additive blending)
  MULTIPLY,  // Multiply scales (position ignored, rotation composed)
  OVERRIDE,  // Completely replace accumulated (weight acts as 0/1 gate)
}

// TransitionState is the phase of a cross-fade.
TransitionState :: enum {
  NONE,     // No transition active
  ACTIVE,   // Transition in progress
  COMPLETE, // Transition finished
}

// Transition is a timed cross-fade between the weights of two layers.
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
@(private)
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
@(private)
blend_position :: proc(
  accumulated: [3]f32,
  new_value: [3]f32,
  weight: f32,
  mode: BlendMode,
) -> [3]f32 {
  switch mode {
  case .REPLACE:
    return accumulated + new_value * weight
  case .ADD:
    return accumulated + new_value * weight
  case .MULTIPLY:
    // Position ignored for multiply mode
    return accumulated
  case .OVERRIDE:
    return new_value if weight > 0.5 else accumulated
  }
  return accumulated
}

// Blend rotation based on mode
@(private)
blend_rotation :: proc(
  accumulated: quaternion128,
  accumulated_weight: f32,
  new_value: quaternion128,
  weight: f32,
  mode: BlendMode,
) -> quaternion128 {
  switch mode {
  case .REPLACE:
    if accumulated_weight > 0 {
      return linalg.quaternion_slerp(
        accumulated,
        new_value,
        weight / (accumulated_weight + weight),
      )
    }
    return new_value
  case .ADD:
    return linalg.quaternion_mul_quaternion(accumulated, new_value)
  case .MULTIPLY:
    // Same as ADD for rotations
    return linalg.quaternion_mul_quaternion(accumulated, new_value)
  case .OVERRIDE:
    return new_value if weight > 0.5 else accumulated
  }
  return accumulated
}

// Blend scale based on mode
@(private)
blend_scale :: proc(
  accumulated: [3]f32,
  new_value: [3]f32,
  weight: f32,
  mode: BlendMode,
) -> [3]f32 {
  switch mode {
  case .REPLACE:
    return accumulated + new_value * weight
  case .ADD:
    return accumulated + new_value * weight
  case .MULTIPLY:
    return accumulated * (1 + (new_value - 1) * weight)
  case .OVERRIDE:
    return new_value if weight > 0.5 else accumulated
  }
  return accumulated
}

// FKLayer plays one clip of the rig (index into Rig.clips).
FKLayer :: struct {
  clip:         int,
  using player: ClipPlayer,
}

// LayerData is what a Layer plays: a clip, an IK chain, or a procedural modifier.
LayerData :: union {
  FKLayer,
  IKTarget,
  ProceduralLayer,
}

// Layer is one weighted, optionally bone-masked source of pose data in an Animator.
Layer :: struct {
  weight:     f32,           // Blend weight (0.0 to 1.0)
  blend_mode: BlendMode,
  bone_mask:  Maybe([]bool), // nil = all bones; owned by the caller
  data:       LayerData,
}
