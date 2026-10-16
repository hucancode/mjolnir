package animation

import "../geometry"
import "core:math"
import "core:math/linalg"

// TailBone is the per-bone state for tail animation.
// position_world lags parent's tip via spring in true world space.
// Bone orientation is derived in pass 2 by aiming at child's lagged position.
TailBone :: struct {
  position_world:    [3]f32, // World-space bone root (state, lags FK)
  position_velocity: [3]f32, // Position velocity (inertia)
  is_initialized:    bool,
}

// TailModifier holds the spring parameters and per-bone state of a tail.
TailModifier :: struct {
  // 0..1, higher = stiffer spring = faster catch-up, faster oscillation
  propagation_speed: f32,
  // Damping ratio: 1 = critical (no overshoot), 0 = undamped, <0 grows, >1 overdamped
  damping:           f32,
  // If true, bones may stretch (pure spring). If false, distance to parent is
  // clamped to bone_length each frame (rigid hinge chain).
  stretch:           bool,
  bones:             []TailBone,
}

// Spring stiffness at propagation_speed = 1.
@(private)
TAIL_MAX_STIFFNESS :: f32(200.0)

// Largest step the tail spring integrates at once; longer frames are clamped
// so the explicit integration stays stable after a hitch.
@(private)
TAIL_MAX_STEP :: f32(1.0 / 30.0)

// PathModifier slides a bone chain along a spline.
PathModifier :: struct {
  spline: Spline([3]f32),
  offset: f32,
  length: f32, // Length of the path segment to fit the skeleton to
  speed:  f32,
  loop:   bool,
  closed: bool, // True if spline was built closed (see spline_build_closed)
}

// SpiderLegConfig describes one leg of a spider rig: its bone chain and stepping parameters.
SpiderLegConfig :: struct {
  root:           string, // first bone of the chain, resolved by add_spider_leg_layer
  chain_length:   u32, // bones in the chain, root first
  constraints:    []IKBoneConstraint, // nil = unconstrained; owned by the layer
  offset:         [3]f32, // rest foot position relative to the leg root, world space
  lift_height:    f32,
  lift_frequency: f32, // seconds per step cycle
  lift_duration:  f32, // seconds the foot is in the air per cycle
  time_offset:    f32, // phase shift of the step cycle
}

// SpiderLeg is a leg config plus stepping state. Positions are in world space.
SpiderLeg :: struct {
  using config: SpiderLegConfig,
  chain_start:  u32, // first entry of this leg in the layer's bone_indices
  target:       [3]f32, // where the foot wants to be
  position:     [3]f32, // current foot position
  last_target:  [3]f32, // last grounded foot position
  last_root:    [3]f32,
  time:         f32,
}

// SpiderLegModifier drives a set of procedurally stepping legs.
SpiderLegModifier :: struct {
  legs: []SpiderLeg,
}

// Modifier is the procedural behaviour of a ProceduralLayer.
Modifier :: union {
  TailModifier,
  PathModifier,
  SpiderLegModifier,
}

// ProceduralLayer applies a Modifier to a chain of bones.
ProceduralLayer :: struct {
  bone_indices: []u32,
  modifier:     Modifier,
}

@(private)
SPIDER_LEG_MIN_LIFT_DISTANCE_RATIO :: f32(0.1)

@(private)
spider_leg_init :: proc(self: ^SpiderLeg, config: SpiderLegConfig) {
  self^ = {
    config      = config,
    target      = config.offset,
    position    = config.offset,
    last_target = config.offset,
  }
}

@(private)
spider_leg_update :: proc(self: ^SpiderLeg, delta_time: f32) {
  if self.lift_duration <= 0 {
    self.position = self.target
    self.last_target = self.target
    return
  }
  target_delta := self.target - self.last_target
  min_lift_distance_sq :=
    linalg.length2(self.offset) *
    SPIDER_LEG_MIN_LIFT_DISTANCE_RATIO *
    SPIDER_LEG_MIN_LIFT_DISTANCE_RATIO
  if linalg.length2(target_delta) <= min_lift_distance_sq {
    self.time += delta_time
    self.position = self.last_target
    return
  }
  prev_time := self.time
  self.time += delta_time
  if self.lift_frequency <= 0 {
    self.position = self.target
    self.last_target = self.target
    return
  }
  phase_time := math.mod_f32(self.time + self.time_offset, self.lift_frequency)
  prev_phase_time := math.mod_f32(prev_time + self.time_offset, self.lift_frequency)
  is_lifting := phase_time < self.lift_duration
  was_lifting := prev_phase_time < self.lift_duration
  if is_lifting {
    t := phase_time / self.lift_duration
    horizontal := linalg.lerp(self.last_target, self.target, t)
    self.position = horizontal + [3]f32{0, compute_parabolic_height(t, self.lift_height), 0}
  } else {
    self.position = self.last_target
  }
  if was_lifting && !is_lifting {
    self.position = self.target
    self.last_target = self.target
  }
}

// Retarget the foot from the leg root's world position (leading it by the
// root's velocity), then step.
@(private)
spider_leg_update_with_root :: proc(self: ^SpiderLeg, delta_time: f32, root_position: [3]f32) {
  root_velocity: [3]f32
  if self.time > 0.0 && delta_time > 0.0 {
    root_velocity = (root_position - self.last_root) / delta_time
  }
  self.target = root_position + self.offset + root_velocity * self.lift_duration
  if self.time == 0.0 && delta_time > 0.0 {
    self.last_target = self.target
    self.position = self.target
  }
  self.last_root = root_position
  spider_leg_update(self, delta_time)
}

// h(t) = 4ht(1-t): parabola with h(0)=0, h(0.5)=h, h(1)=0
@(private)
compute_parabolic_height :: proc "contextless" (t: f32, max_height: f32) -> f32 {
  return 4.0 * max_height * t * (1.0 - t)
}

// Modifiers edit the skeleton-space pose by bone index, blended by `layer_weight`.

// Aim `bone` so its Y axis points along `direction`, blended by `weight`.
@(private = "file")
aim_bone :: proc(rotations: []quaternion128, bone: u32, direction: [3]f32, weight: f32) {
  if linalg.length2(direction) < 1e-6 do return
  rot := rotations[bone]
  aim := linalg.quaternion_between_two_vector3(geometry.qy(rot), linalg.normalize(direction))
  rotations[bone] = linalg.quaternion_slerp(rot, aim * rot, weight)
}

@(private = "file")
transform_point :: #force_inline proc(m: matrix[4, 4]f32, p: [3]f32) -> [3]f32 {
  return (m * [4]f32{p.x, p.y, p.z, 1}).xyz
}

@(private)
tail_modifier_update :: proc(
  params: ^TailModifier,
  bone_indices: []u32,
  positions: [][3]f32,
  rotations: []quaternion128,
  bone_lengths: []f32,
  layer_weight: f32,
  delta_time: f32,
  root_world: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) {
  chain_length := len(bone_indices)
  if chain_length < 2 do return
  if len(params.bones) != chain_length do return
  if bone_lengths == nil do return
  root_world_inv := linalg.matrix4_inverse(root_world)
  delta_time := min(delta_time, TAIL_MAX_STEP)
  stiffness := TAIL_MAX_STIFFNESS * clamp(params.propagation_speed, 0.0, 1.0)
  damping_coeff := 2.0 * math.sqrt(stiffness) * params.damping
  // Pass 1: spring-damp each child bone's world position toward its parent's
  // FK tip in world space. State stored in world coords so node translation
  // and FK rotation both produce drag through the chain.
  for i in 1 ..< chain_length {
    bone_idx := bone_indices[i]
    parent_idx := bone_indices[i - 1]
    bone_state := &params.bones[i]
    bone_length := bone_lengths[bone_idx]
    parent_pos_world := transform_point(root_world, positions[parent_idx])
    parent_up := geometry.qy(rotations[parent_idx])
    parent_up_world := linalg.normalize((root_world * [4]f32{parent_up.x, parent_up.y, parent_up.z, 0}).xyz)
    parent_tip_world := parent_pos_world + parent_up_world * bone_length
    if !bone_state.is_initialized {
      bone_state.position_world = parent_tip_world
      bone_state.is_initialized = true
    }
    pos_spring := (parent_tip_world - bone_state.position_world) * stiffness
    pos_damp := -bone_state.position_velocity * damping_coeff
    bone_state.position_velocity += (pos_spring + pos_damp) * delta_time
    bone_state.position_world += bone_state.position_velocity * delta_time
    if !params.stretch {
      delta := bone_state.position_world - parent_pos_world
      d := linalg.length(delta)
      if d > 0.001 {
        radial := delta / d
        bone_state.position_world = parent_pos_world + radial * bone_length
        // Remove the radial component of velocity to avoid spring fighting
        // the constraint each frame.
        bone_state.position_velocity -= radial * linalg.dot(bone_state.position_velocity, radial)
      }
    }
    if layer_weight <= 0 do continue
    lagged := transform_point(root_world_inv, bone_state.position_world)
    positions[bone_idx] = linalg.lerp(positions[bone_idx], lagged, layer_weight)
  }
  // At weight 0 only the spring state advances; the pose is left as is.
  if layer_weight <= 0 do return
  for i in 0 ..< chain_length - 1 {
    bone_idx := bone_indices[i]
    aim_bone(rotations, bone_idx, positions[bone_indices[i + 1]] - positions[bone_idx], layer_weight)
  }
  // Last bone: aim along the direction from its parent to itself so it
  // continues the chain instead of snapping back to FK orientation.
  last_idx := bone_indices[chain_length - 1]
  prev_idx := bone_indices[chain_length - 2]
  aim_bone(rotations, last_idx, positions[last_idx] - positions[prev_idx], layer_weight)
}

@(private)
path_modifier_update :: proc(
  params: ^PathModifier,
  bone_indices: []u32,
  positions: [][3]f32,
  rotations: []quaternion128,
  bone_lengths: []f32,
  layer_weight: f32,
  delta_time: f32,
) {
  chain_length := len(bone_indices)
  if chain_length < 2 || len(params.spline.points) < 2 do return
  if bone_lengths == nil do return
  spline_length := spline_arc_length(params.spline)
  if spline_length <= 0 do return
  if params.speed != 0 {
    params.offset += params.speed * delta_time
    if params.loop {
      params.offset = math.mod_f32(params.offset, spline_length)
    } else {
      params.offset = clamp(params.offset, 0.0, spline_length)
    }
  }
  total_chain_length: f32 = 0
  for i in 1 ..< chain_length {
    total_chain_length += bone_lengths[bone_indices[i]]
  }
  if total_chain_length <= 0 || layer_weight <= 0 do return
  segment_length :=
    params.length if params.length > 0 else spline_length - params.offset
  cumulative_length: f32 = 0
  for i in 0 ..< chain_length {
    bone_idx := bone_indices[i]
    s := params.offset + (cumulative_length / total_chain_length) * segment_length
    if params.loop {
      s = math.mod_f32(s, spline_length)
    } else {
      s = clamp(s, 0, spline_length)
    }
    path_pos := spline_sample_uniform(params.spline, s)
    positions[bone_idx] = linalg.lerp(positions[bone_idx], path_pos, layer_weight)
    if i < chain_length - 1 {
      cumulative_length += bone_lengths[bone_indices[i + 1]]
    }
  }
  for i in 0 ..< chain_length - 1 {
    bone_idx := bone_indices[i]
    aim_bone(rotations, bone_idx, positions[bone_indices[i + 1]] - positions[bone_idx], layer_weight)
  }
  bone_idx := bone_indices[chain_length - 1]
  s := params.offset + segment_length + 0.01
  s = math.mod_f32(s, spline_length) if params.loop else clamp(s, 0, spline_length)
  tangent_pos := spline_sample_uniform(params.spline, s)
  aim_bone(rotations, bone_idx, tangent_pos - positions[bone_idx], layer_weight)
}

@(private)
spider_leg_modifier_update :: proc(
  params: ^SpiderLegModifier,
  bone_indices: []u32,
  positions: [][3]f32,
  rotations: []quaternion128,
  bone_lengths: []f32,
  layer_weight: f32,
  delta_time: f32,
  root_world: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) {
  root_world_inv := linalg.matrix4_inverse(root_world)
  for &leg in params.legs {
    chain_len := int(leg.chain_length)
    if chain_len < 2 do continue
    chain := bone_indices[leg.chain_start:][:chain_len]
    root_skeleton := positions[chain[0]]
    // Stepping runs in world space so feet stay planted as the body moves
    spider_leg_update_with_root(&leg, delta_time, transform_point(root_world, root_skeleton))
    if layer_weight <= 0 do continue
    foot := transform_point(root_world_inv, leg.position)
    chain_lengths := make([]f32, chain_len - 1, context.temp_allocator)
    for b, i in chain do if i > 0 do chain_lengths[i - 1] = bone_lengths[b]
    // Pole above the leg's midpoint, perpendicular to the leg, so the knee
    // bends upward/outward
    leg_dir := foot - root_skeleton
    up := [3]f32{0, 1, 0}
    pole_offset := up
    if d2 := linalg.dot(leg_dir, leg_dir); d2 > 1e-8 do pole_offset = up - leg_dir * linalg.dot(up, leg_dir) / d2
    if linalg.length2(pole_offset) < 1e-8 do pole_offset = {1, 0, 0}
    pole := (root_skeleton + foot) * 0.5 + linalg.normalize(pole_offset) * 2.0
    fabrik_solve(
      positions,
      rotations,
      IKTarget {
        bone_indices = chain,
        bone_lengths = chain_lengths,
        constraints = leg.constraints,
        target_position = foot,
        pole_vector = pole,
        pole_weight = 0.8,
        max_iterations = 10,
        tolerance = 0.01,
        weight = layer_weight,
        enabled = true,
      },
    )
  }
}
