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

// PlayMode selects what a clip does when it reaches its end.
PlayMode :: enum {
  LOOP,
  ONCE,
  PING_PONG,
}

// ClipPlayer is a play head over one clip, for animating outside an Animator
// (clip_player_update). A plain value: `ClipPlayer{speed = 1}` loops from the start. ONCE
// clamps at the clip's end and stops; PING_PONG flips speed at either end.
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

// BlendMode selects how a clip layer combines with the pose of the clip layers before it.
BlendMode :: enum {
  REPLACE,  // Weighted average while total weight <= 1; beyond that the layer lerps over what is below it
  ADD,      // Adds the layer's offset from the rest pose, scaled by weight
  MULTIPLY, // Multiplies scale and composes rotation, scaled by weight (position ignored)
  OVERRIDE, // Replaces the accumulated pose (weight acts as a 0/1 gate at 0.5)
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

// LayerHandle identifies a layer of an Animator (layer_create).
LayerHandle :: distinct u32

// ClipHandle identifies a clip of a Rig (find_clip).
ClipHandle :: distinct u32

// LayerParams is what a layer does: play a clip, or edit the pose with an IK chain, a tail
// spring, a path, a stepping leg or your own CustomApply. Its fields are inputs only: edit
// them any time through layer_params.
LayerParams :: union {
  ClipParams,
  IKParams,
  TailParams,
  PathParams,
  LegParams,
  CustomParams,
}

// ClipParams plays one clip of the rig. Its layer's bones are the bones it animates (none =
// all), blended into the clip layers before it by blend_mode.
ClipParams :: struct {
  clip:       ClipHandle,
  speed:      f32, // 1 = authored speed; negative plays backwards
  mode:       PlayMode,
  blend_mode: BlendMode,
}

// CustomApply edits `pose` for a custom layer: `bones` are the layer's bones and `state` its
// own floats (zero at creation, kept between updates). Edit the pose at full strength; the
// animator blends the result by the layer's weight and moves the bones' descendants after.
// `fresh` is true on the layer's first update.
CustomApply :: #type proc(pose: Pose, bones: []u32, state: []f32, values: [8]f32, delta_time: f32, fresh: bool)

// CustomParams runs your own procedural algorithm as a layer. `values` are its inputs;
// `state` is how many floats of persistent state it keeps (fixed at layer_create).
CustomParams :: struct {
  apply:  CustomApply,
  values: [8]f32,
  state:  u32,
}

// A range of one of the Animator's pools.
@(private)
Range :: struct {
  start, count: u32,
}

// A weight change over time; duration 0 = none.
@(private)
Fade :: struct {
  from, to, elapsed, duration: f32,
  curve:                       ease.Ease,
}

// One slot of the layer stack; params == nil marks a free slot.
@(private)
Layer :: struct {
  weight:   f32,
  fade:     Fade,
  priority: i32,
  bones:    Range, // into Animator.bones
  state:    Range, // into Animator.state, the kind's own floats
  fresh:    bool, // not updated yet
  params:   LayerParams,
}

@(private)
fade_advance :: proc(self: ^Layer, delta_time: f32) {
  f := &self.fade
  if f.duration <= 0 do return
  f.elapsed += delta_time
  if f.elapsed >= f.duration {
    self.weight = f.to
    f^ = {}
    return
  }
  self.weight = linalg.lerp(f.from, f.to, ease.ease(f.curve, f.elapsed / f.duration))
}
