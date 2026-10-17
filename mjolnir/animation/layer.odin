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
    // Reflect the overshoot back into the clip and turn around.
    if self.time >= duration {
      self.time = 2 * duration - self.time
      self.speed = -abs(self.speed)
    } else if self.time < 0 {
      self.time = -self.time
      self.speed = abs(self.speed)
    }
    self.time = clamp(self.time, 0, duration)
  }
}

// BlendMode selects how a layer combines with the pose accumulated from the layers before it.
BlendMode :: enum {
  REPLACE,  // Weighted average while total weight <= 1; beyond that the layer lerps over what is below it
  ADD,      // Adds the layer's offset from the rest pose, scaled by weight
  MULTIPLY, // Multiplies scale and composes rotation, scaled by weight (position ignored)
  OVERRIDE, // Replaces the accumulated pose (weight acts as a 0/1 gate at 0.5)
}

// TransitionState is the phase of a cross-fade.
TransitionState :: enum {
  NONE,     // No transition active
  ACTIVE,   // Transition in progress
  COMPLETE, // Transition finished
}

// Transition is a timed cross-fade between the weights of two layers.
Transition :: struct {
  from_layer: LayerHandle,
  to_layer:   LayerHandle,
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
  if int(self.from_layer) >= len(layers) || int(self.to_layer) >= len(layers) {
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

// Blend one bone's sample `s` (weight `w`) into the accumulated local pose `acc`, whose
// REPLACE/OVERRIDE weight so far is `acc_w`. `rest` is the bone's rest pose, the
// reference ADD offsets are measured from.
@(private)
blend_sample :: proc(acc: ^TRS, acc_w: ^f32, s, rest: TRS, w: f32, mode: BlendMode) {
  id := linalg.QUATERNIONF32_IDENTITY
  w := min(w, 1)
  switch mode {
  case .REPLACE:
    // Earlier weight beyond what is left after this layer is given up, so weights
    // summing to <= 1 average and heavier stacks let later layers win.
    prior := min(acc_w^, 1 - w)
    t := w / (prior + w)
    acc.position = linalg.lerp(acc.position, s.position, t)
    acc.rotation = linalg.quaternion_slerp(acc.rotation, s.rotation, t)
    acc.scale = linalg.lerp(acc.scale, s.scale, t)
    acc_w^ = prior + w
  case .ADD:
    acc.position += (s.position - rest.position) * w
    delta := linalg.quaternion_inverse(rest.rotation) * s.rotation
    acc.rotation = linalg.normalize(acc.rotation * linalg.quaternion_slerp(id, delta, w))
    acc.scale *= 1 + (s.scale / rest.scale - 1) * w
  case .MULTIPLY:
    acc.rotation = linalg.normalize(acc.rotation * linalg.quaternion_slerp(id, s.rotation, w))
    acc.scale *= 1 + (s.scale - 1) * w
  case .OVERRIDE:
    if w > 0.5 {
      acc^ = s
      acc_w^ = 1
    }
  }
}

// FKLayer plays one clip of the rig (index into Rig.clips).
FKLayer :: struct {
  clip:         ClipHandle,
  using player: ClipPlayer,
}

// LayerData is what a Layer plays: a clip, an IK chain, or a procedural modifier.
LayerData :: union {
  FKLayer,
  IKTarget,
  ProceduralLayer,
}

// LayerHandle identifies a layer of an Animator (clip_layer_create and the other *_layer_create).
LayerHandle :: distinct u32

// ClipHandle identifies a clip of a Rig (find_clip).
ClipHandle :: distinct u32

// Layer is one weighted, optionally bone-masked source of pose data in an Animator.
Layer :: struct {
  weight:     f32,           // Blend weight (0.0 to 1.0)
  blend_mode: BlendMode,
  bone_mask:  Maybe([]bool), // nil = all bones; owned by the caller
  data:       LayerData,
}
