# Animation Module (`mjolnir/animation`)

The Animation module provides skeletal animation, IK, procedural animation modifiers, and spline utilities.

## Spline System

Splines provide smooth curves through control points, useful for paths, camera movement, and procedural animation.

```odin
import "../../mjolnir/animation"

// Create a spline with type and capacity
spline := animation.spline_create([3]f32, capacity = 10)
defer animation.spline_destroy(&spline)

// Add control points
animation.spline_add_point(&spline, {0, 0, 0})
animation.spline_add_point(&spline, {5, 2, 0})
animation.spline_add_point(&spline, {10, 0, 5})

// Validate and build arc-length table for uniform sampling
if animation.spline_validate(spline) {
  animation.spline_build_arc_table(&spline, subdivisions = 200)
  
  // Sample along spline uniformly by arc length
  s := 0.5 // 0.0 to 1.0
  position := animation.spline_sample_uniform(spline, s)
  
  // Or sample by parametric t
  position := animation.spline_sample(spline, t = 0.5)
}
```

## Animation Layers

Animation layers allow blending multiple animations together. See [World Module](world.html#animation) for layer management functions.

### Blend Modes

```odin
// REPLACE mode: Standard blending (lerp between animations)
// Use for normal animation clips
world.add_animation_layer(
  &engine.world,
  node,
  "Walk",
  weight = 1.0,
  blend_mode = .REPLACE,
)

// ADD mode: Additive blending (add animation on top)
// Only use for animations specifically authored as additive deltas
world.add_animation_layer(
  &engine.world,
  node,
  "Breathing",
  weight = 0.5,
  blend_mode = .ADD,
)
```

### Layer Weights

```odin
// Blend between walk and run by adjusting weights
walk_weight := 0.7
run_weight := 0.3

world.set_animation_layer_weight(&engine.world, node, 0, walk_weight)
world.set_animation_layer_weight(&engine.world, node, 1, run_weight)

// Animate weight smoothly
target := enable_layer ? 1.0 : 0.0
current_weight = math.lerp(current_weight, target, delta_time * blend_speed)
```

## IK (Inverse Kinematics)

IK solves bone chains to reach target positions, useful for foot placement, hand reaching, and look-at.

```odin
// Define bone chain from root to tip
bone_chain := []string{"Hips", "Spine", "Neck", "Head"}

// Set target and pole position
target_pos := [3]f32{0, 2, 5}  // Where the chain should reach
pole_pos := [3]f32{0, 3, 2}    // Hints the bending direction

// Add IK layer
world.add_ik_layer(
  &engine.world,
  node,
  bone_chain,
  target_pos,
  pole_pos,
  weight = 1.0,
  layer_index = -1, // -1 = append new layer
)

// Update target each frame
world.set_ik_layer_target(&engine.world, node, layer_idx, new_target, new_pole)
```

## Procedural Animation Modifiers

### Tail Modifier

Creates natural follow-through motion for tails, hair, antennas, etc. Bones react to parent movement with physics-like drag.

```odin
// Add tail modifier
success := world.add_tail_modifier_layer(
  &engine.world,
  node,
  root_bone_name = "tail_root",
  tail_length = 10,                    // Number of bones
  propagation_speed = 0.85,            // Reaction strength (0-1)
  damping = 0.1,                       // Return speed (0-1, higher = slower)
  weight = 1.0,
  reverse_chain = false,               // True if bones are ordered tip->root
)

// Parameters guide:
// - propagation_speed: How strongly bones counter-rotate parent motion
//   Higher = more immediate reaction, creates visible drag
// - damping: How quickly bones return to rest pose
//   Higher = slower return, longer wave propagation
```

### Single Bone Rotation Modifier

Directly control one bone's rotation, useful for root motion that drives other modifiers.

```odin
// Add modifier and get pointer
modifier := world.add_single_bone_rotation_modifier_layer(
  &engine.world,
  node,
  bone_name = "root",
  weight = 1.0,
  layer_index = -1,
) or_else nil

// Update rotation each frame
if modifier != nil {
  angle := math.sin(time) * math.PI * 0.3
  modifier.rotation = linalg.quaternion_angle_axis_f32(angle, {0, 1, 0})
}
```

## Keyframe Animation

For procedural animation, you can create custom animation clips:

```odin
// Create animation clip
clip_handle, clip_ptr := cont.alloc(&engine.world.animation_clips, world.ClipHandle)

clip_ptr.name = "MyAnimation"
clip_ptr.duration = 2.0
clip_ptr.channels = make([]animation.Channel, bone_count)

// Initialize channel with procedural keyframes
mjolnir.init_animation_channel(
  engine,
  clip_handle,
  channel_idx = 0,
  position_count = 10,
  rotation_count = 10,
  position_fn = proc(i: int) -> [3]f32 {
    t := f32(i) / 9.0
    return {t * 5.0, math.sin(t * math.PI) * 2.0, 0}
  },
  rotation_fn = proc(i: int) -> quaternion128 {
    t := f32(i) / 9.0
    return linalg.quaternion_angle_axis_f32(t * math.TAU, {0, 1, 0})
  },
)
```

## Interpolation Modes

Animation channels support different interpolation:

```odin
animation.InterpolationMode:
  .LINEAR       // Linear interpolation (smooth)
  .STEP         // Step interpolation (no smoothing)
  .CUBIC_SPLINE // Cubic spline (smoothest, with tangents)
```
