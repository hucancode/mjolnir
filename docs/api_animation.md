# `mjolnir/animation` — API Reference

Layer 1. Pure animation data + procs. Knows nothing about scene nodes or GPU.
`world` is the layer that *applies* these to skeletons.

## Keyframes & interpolation

```odin
InterpolationMode :: enum { LINEAR, STEP, CUBICSPLINE }

LinearKeyframe($T)      :: struct { time: f32, value: T }
StepKeyframe($T)        :: struct { time: f32, value: T }
CubicSplineKeyframe($T) :: struct { time: f32, in_tangent: T, value: T, out_tangent: T }

Keyframe($T) :: union {
  LinearKeyframe(T),
  StepKeyframe(T),
  CubicSplineKeyframe(T),
}
```

| Proc | Purpose |
|---|---|
| `keyframe_time(kf) -> f32` | Time of any keyframe variant. |
| `keyframe_value(kf) -> T` | Value of any keyframe variant. |
| `keyframe_sample(frames: []Keyframe(T), t: f32, fallback: T) -> T` | Sample track at time `t`. Dispatches to the correct interpolator pair. |

There are 9 interpolator pair procs (`sample_linear_linear`, `sample_linear_step`,
`sample_linear_cubic`, `sample_step_linear`, ..., `sample_cubic_cubic`); they
are used internally by `keyframe_sample`. See source if you need to bypass it.

## Spline

Catmull-Rom / Hermite spline over any vector type with optional uniform
arc-length sampling.

```odin
Spline($T) :: struct {
  points:   []T,
  times:    []f32,
  arc_table: Maybe(Spline_Arc_Length_Table(T)),
}

spline_create($T, count: int) -> Spline(T)
spline_destroy(s: ^Spline(T))
spline_validate(s: Spline(T)) -> bool
spline_sample  (s: Spline(T), t: f32) -> T
```

Hermite basis helpers (`hermite_h00`, `h10`, `h01`, `h11`,
`catmull_rom_tangent`) are file-private; user code should call
`spline_sample`.

## Channel & Clip

```odin
Channel :: struct {
  positions: []Keyframe([3]f32),
  rotations: []Keyframe(quaternion128),
  scales:    []Keyframe([3]f32),
}

Clip :: struct {
  name:     string,
  duration: f32,
  channels: []Channel,
}
```

```odin
channel_init(channel, position_count=0, rotation_count=0, scale_count=0,
             position_interpolation=.LINEAR, rotation_interpolation=.LINEAR,
             scale_interpolation=.LINEAR, duration=1.0)
channel_destroy(channel)
channel_sample_some(c, t) -> (Maybe([3]f32), Maybe(quaternion128), Maybe([3]f32))
channel_sample_all (c, t) -> ([3]f32, quaternion128, [3]f32)

clip_create  (channel_count: int, duration: f32 = 1.0, name: string = "") -> Clip
clip_destroy (clip)
```

## Layers

```odin
Status     :: enum { PLAYING, PAUSED, STOPPED }
PlayMode   :: enum { LOOP, ONCE, PING_PONG }
BlendMode  :: enum {
  REPLACE,    // weighted blend (LERP/SLERP)
  ADD,        // additive
  MULTIPLY,   // scales / multiplicative blend
  OVERRIDE,   // hard switch when weight > 0.5
}

TransitionState :: enum { NONE, ACTIVE, COMPLETE }
Transition :: struct {
  from_layer: int, to_layer: int,
  duration: f32, elapsed: f32,
  curve: ease.Ease,
  state: TransitionState,
}

FKLayer :: struct {
  clip_handle: u64,
  mode:        PlayMode,
  status:      Status,
  time:        f32,
  duration:    f32,
  speed:       f32,
}

LayerData :: union { FKLayer, IKLayer, ProceduralLayer }

Layer :: struct {
  weight:     f32,
  blend_mode: BlendMode,
  bone_mask:  Maybe([]bool),  // nil = all bones
  data:       LayerData,
}
```

```odin
layer_init_fk(self, clip_handle, duration, weight=1, mode=.LOOP, speed=1, blend_mode=.REPLACE)
layer_init_ik(self, target: IKTarget, weight=1, blend_mode=.REPLACE)
layer_update (self, delta_time)
```

Blend helpers (used internally; available if you implement custom samplers):

```odin
blend_position(accumulated, new_value, weight, mode) -> [3]f32
blend_rotation(accumulated, accumulated_weight, new_value, weight, mode) -> quaternion128
blend_scale   (accumulated, new_value, weight, mode) -> [3]f32
```

## IK (FABRIK)

```odin
IKTarget :: struct {
  bone_indices:   []u32,    // root → tip; min 2
  bone_lengths:   []f32,    // cached; len == len(bone_indices) - 1
  target_position: [3]f32,
  pole_vector:     [3]f32,
  pole_weight:     f32,     // 0..1
  max_iterations:  int,
  tolerance:       f32,
  weight:          f32,
  enabled:         bool,
}

BoneTransform :: struct {
  world_position: [3]f32,
  world_rotation: quaternion128,
  world_matrix:   matrix[4, 4]f32,
}

IKLayer :: struct { target: IKTarget }

fabrik_solve(world_transforms: []BoneTransform, target: IKTarget)
update_transforms_from_positions(world_transforms, bone_indices, positions, pole_vector, pole_weight)
```

## Procedural modifiers

```odin
TailBone :: struct {
  target_tip_world: [3]f32,
  is_initialized:   bool,
}

TailModifier :: struct {
  propagation_speed: f32,
  damping:           f32,
  bones:             []TailBone,
}

PathModifier :: struct {
  spline: Spline([3]f32),
  offset: f32,
  length: f32,
  speed:  f32,
  loop:   bool,
}

SingleBoneRotationModifier :: struct {
  bone_index: u32,
  rotation:   quaternion128,
}

IKDebugInfo :: struct {
  positions: [][3]f32,
  target:    [3]f32,
  pole:      [3]f32,
  has_pole:  bool,
}

SpiderLegModifier :: struct {
  legs:          []SpiderLeg,
  chain_starts:  []u32,
  chain_lengths: []u32,
  debug_info:    []IKDebugInfo,
}

Modifier :: union { TailModifier, PathModifier, SpiderLegModifier, SingleBoneRotationModifier }

ProceduralState :: struct {
  bone_indices:    []u32,
  accumulated_time: f32,
  modifier:        Modifier,
}

ProceduralLayer :: struct { state: ProceduralState }
```

```odin
tail_modifier_update(state, params, delta_time, world_transforms, layer_weight, bone_lengths)
```

## Spider leg

```odin
SPIDER_LEG_MIN_LIFT_DISTANCE_RATIO :: 0.1   // motion threshold to lift foot

SpiderLeg :: struct {
  feet_offset:           [3]f32,
  feet_target:           [3]f32,
  feet_lift_height:      f32,
  feet_lift_frequency:   f32,
  feet_lift_time_offset: f32,
  feet_lift_duration:    f32,
  feet_position:         [3]f32,
  feet_last_target:      [3]f32,
  last_root_position:    [3]f32,
  accumulated_time:      f32,
}

SpiderLegConfig :: struct {
  initial_offset: [3]f32,
  lift_height:    f32,
  lift_frequency: f32,
  lift_duration:  f32,
  time_offset:    f32,
}

spider_leg_init(self, initial_offset, lift_height=0.5, lift_frequency=2,
                lift_duration=0.4, time_offset=0)
spider_leg_update(self, delta_time)
spider_leg_update_with_root(self, delta_time, root_position)
compute_parabolic_height(t: f32, max_height: f32) -> f32   // h(t) = 4h·t·(1-t)
```

## Evaluation flow (reference)

```text
layer_update             advance layer.time per PlayMode/speed
channel_sample_all       sample (pos, rot, scale) at t
keyframe_sample          dispatch to interpolator pair
fabrik_solve             positional IK (forward+backward sweep)
update_transforms_from_positions   recover rotations w/ pole
tail / path / spider modifier_update   procedural deformations
blend_*                  combine layers in order with weights & masks
```

`world.update_skeletal_animations(world, dt)` runs this whole pipeline per
skinned node and writes bone matrices into `NodeSkinning.matrices`.
