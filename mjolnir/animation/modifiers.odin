package animation

import "../geometry"
import "core:math"
import "core:math/linalg"

// Per-bone state for tail animation
// position_world lags parent's tip via spring in true world space.
// Bone orientation is derived in pass 2 by aiming at child's lagged position.
TailBone :: struct {
  position_world:    [3]f32, // World-space bone root (state, lags FK)
  position_velocity: [3]f32, // Position velocity (inertia)
  is_initialized:    bool,
}

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

// Max spring stiffness mapped from propagation_speed = 1.
// Higher = snappier and faster oscillations.
@(private)
TAIL_MAX_STIFFNESS :: f32(200.0)

PathModifier :: struct {
  spline: Spline([3]f32),
  offset: f32,
  length: f32, // Length of the path segment to fit the skeleton to
  speed:  f32,
  loop:   bool,
  closed: bool, // True if spline was built closed (see spline_build_closed)
}

// One leg of a spider rig: its bone chain and stepping parameters.
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

// Leg config plus stepping state. Positions are in world space.
SpiderLeg :: struct {
  using config: SpiderLegConfig,
  chain_start:  u32, // first entry of this leg in the layer's bone_indices
  target:       [3]f32, // where the foot wants to be
  position:     [3]f32, // current foot position
  last_target:  [3]f32, // last grounded foot position
  last_root:    [3]f32,
  time:         f32,
}

SpiderLegModifier :: struct {
  legs: []SpiderLeg,
}

Modifier :: union {
  TailModifier,
  PathModifier,
  SpiderLegModifier,
}

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
  // First update: plant the foot at its target
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

// Modifier updates work on the skeleton-space pose (`positions`/`rotations`,
// indexed by bone) and blend their result in by `layer_weight`.
// `root_world` is the skinned object's world matrix.

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
    // Rigid hinge: pin position to bone_length distance from parent.
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
    lagged := transform_point(root_world_inv, bone_state.position_world)
    positions[bone_idx] = linalg.lerp(positions[bone_idx], lagged, layer_weight)
  }
  // Pass 2: orient each parent bone toward its child's (lagged) position.
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
  if total_chain_length <= 0 do return
  segment_length :=
    params.length if params.length > 0 else spline_length - params.offset
  // Position all bones along the path segment [offset, offset + segment_length]
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
  // Orient each parent bone toward its child
  for i in 0 ..< chain_length - 1 {
    bone_idx := bone_indices[i]
    aim_bone(rotations, bone_idx, positions[bone_indices[i + 1]] - positions[bone_idx], layer_weight)
  }
  // Last bone has no child: aim along the spline tangent
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
    foot := transform_point(root_world_inv, leg.position)
    chain_lengths := make([]f32, chain_len - 1, context.temp_allocator)
    fk_positions := make([][3]f32, chain_len, context.temp_allocator)
    fk_rotations := make([]quaternion128, chain_len, context.temp_allocator)
    for b, i in chain {
      if i > 0 do chain_lengths[i - 1] = bone_lengths[b]
      fk_positions[i] = positions[b]
      fk_rotations[i] = rotations[b]
    }
    // Pole above the leg's midpoint, perpendicular to the leg, so the knee
    // bends upward/outward
    leg_dir := foot - root_skeleton
    up := [3]f32{0, 1, 0}
    pole_offset := up - leg_dir * linalg.dot(up, leg_dir) / linalg.dot(leg_dir, leg_dir)
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
        weight = 1.0,
        enabled = true,
      },
    )
    for b, i in chain {
      positions[b] = linalg.lerp(fk_positions[i], positions[b], layer_weight)
      rotations[b] = linalg.quaternion_slerp(fk_rotations[i], rotations[b], layer_weight)
    }
  }
}
