package animation

import "../geometry"
import "core:math/ease"
import "core:math/linalg"
import "core:mem"
import "core:slice"

// A skeleton plus the clips authored for it. Asset data, shared by every
// Animator that plays it.
Rig :: struct {
  skeleton: Skeleton,
  clips:    [dynamic]Clip,
}

rig_destroy :: proc(self: ^Rig) {
  skeleton_destroy(&self.skeleton)
  for &c in self.clips do clip_destroy(&c)
  delete(self.clips)
  self^ = {}
}

find_clip :: proc(self: ^Rig, name: string) -> (index: int, ok: bool) #optional_ok {
  for c, i in self.clips do if c.name == name do return i, true
  return -1, false
}

// Per-instance animation state of one skeleton. Owns its layer stack and the
// instance pose; the Skeleton definition stays shared and untouched.
//   local     - per-bone local transform, rebuilt each update
//   positions, rotations, scales
//             - per-bone skeleton-space transform (parent chain applied)
//   palette   - skinning matrices (skeleton-space * inverse_bind), what a
//               renderer uploads
// All pose arrays share one allocation.
Animator :: struct {
  layers:     [dynamic]Layer,
  transition: Transition,
  local:      []TRS,
  positions:  [][3]f32,
  rotations:  []quaternion128,
  scales:     [][3]f32,
  palette:    []matrix[4, 4]f32,
}

animator_init :: proc(self: ^Animator, rig: ^Rig) -> bool {
  skel := &rig.skeleton
  n := bone_count(skel)
  size := n * (size_of(matrix[4, 4]f32) + size_of(quaternion128) + 2 * size_of([3]f32) + size_of(TRS))
  base, err := mem.alloc(max(size, 1), 16)
  if err != nil do return false
  p := uintptr(base)
  self.palette = ([^]matrix[4, 4]f32)(rawptr(p))[:n]
  p += uintptr(n * size_of(matrix[4, 4]f32))
  self.rotations = ([^]quaternion128)(rawptr(p))[:n]
  p += uintptr(n * size_of(quaternion128))
  self.local = ([^]TRS)(rawptr(p))[:n]
  p += uintptr(n * size_of(TRS))
  self.positions = ([^][3]f32)(rawptr(p))[:n]
  p += uintptr(n * size_of([3]f32))
  self.scales = ([^][3]f32)(rawptr(p))[:n]
  copy(self.local, skel.rest)
  pose_model(self, skel)
  update_palette(self, skel)
  return true
}

animator_destroy :: proc(self: ^Animator) {
  for &l in self.layers do layer_destroy(&l)
  delete(self.layers)
  if len(self.palette) > 0 do mem.free(raw_data(self.palette))
  self^ = {}
}

@(private)
layer_destroy :: proc(self: ^Layer) {
  switch &d in self.data {
  case FKLayer:
  case IKTarget:
    delete(d.bone_indices)
    delete(d.bone_lengths)
    delete(d.constraints)
  case ProceduralLayer:
    delete(d.bone_indices)
    switch &m in d.modifier {
    case TailModifier:
      delete(m.bones)
    case PathModifier:
      spline_destroy(&m.spline)
    case SpiderLegModifier:
      for leg in m.legs do delete(leg.constraints)
      delete(m.legs)
    }
  }
  self^ = {}
}

// Skeleton-space transform of bone `i` from its local transform and its
// parent's skeleton-space transform (scale does not shear).
@(private)
compose_bone :: #force_inline proc(self: ^Animator, i: u32, parent: i32) {
  l := self.local[i]
  if parent < 0 {
    self.positions[i], self.rotations[i], self.scales[i] = l.position, l.rotation, l.scale
    return
  }
  pr := self.rotations[parent]
  ps := self.scales[parent]
  self.positions[i] = self.positions[parent] + geometry.qmv(pr, ps * l.position)
  self.rotations[i] = pr * l.rotation
  self.scales[i] = ps * l.scale
}

// Skeleton-space pose from the local pose, parents first.
@(private)
pose_model :: proc(self: ^Animator, skel: ^Skeleton) {
  for i in skel.order do compose_bone(self, i, skel.parents[i])
}

// Recompute descendants of `moved` bones that were not moved themselves.
@(private)
repropagate :: proc(self: ^Animator, skel: ^Skeleton, moved: []bool) {
  dirty := make([]bool, len(moved), context.temp_allocator)
  for i in skel.order {
    p := skel.parents[i]
    if p < 0 || moved[i] || !(moved[p] || dirty[p]) do continue
    compose_bone(self, i, p)
    dirty[i] = true
  }
}

@(private)
update_palette :: proc(self: ^Animator, skel: ^Skeleton) {
  for i in 0 ..< len(self.palette) {
    self.palette[i] = linalg.matrix4_from_trs(self.positions[i], self.rotations[i], self.scales[i]) * skel.inverse_bind[i]
  }
}

// Advance every layer by `delta_time` and rebuild the pose. `root_world` is the
// world matrix of the skinned object; world-space IK targets and procedural
// modifiers use it. Returns the skinning palette (also in self.palette).
animator_update :: proc(
  self: ^Animator,
  rig: ^Rig,
  delta_time: f32,
  root_world: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) -> []matrix[4, 4]f32 {
  skel := &rig.skeleton
  n := bone_count(skel)
  if n == 0 || len(self.local) != n do return self.palette
  transition_update(&self.transition, self.layers[:], delta_time)
  for &layer in self.layers {
    fk := (&layer.data.(FKLayer)) or_continue
    if fk.clip < 0 || fk.clip >= len(rig.clips) do continue
    playback_advance(fk, rig.clips[fk.clip].duration, delta_time)
  }
  // FK: blend every clip layer into the local pose
  acc_pos := make([][3]f32, n, context.temp_allocator)
  acc_rot := make([]quaternion128, n, context.temp_allocator)
  acc_scl := make([][3]f32, n, context.temp_allocator)
  acc_w := make([]f32, n, context.temp_allocator)
  slice.fill(acc_rot, linalg.QUATERNIONF32_IDENTITY)
  for &layer in self.layers {
    if layer.weight <= 0 do continue
    fk := layer.data.(FKLayer) or_continue
    if fk.clip < 0 || fk.clip >= len(rig.clips) do continue
    clip := &rig.clips[fk.clip]
    mask, has_mask := layer.bone_mask.?
    w := layer.weight
    for i in 0 ..< n {
      if has_mask && (i >= len(mask) || !mask[i]) do continue
      s := skel.rest[i]
      clip_sample_trs(clip, i, fk.time, &s)
      acc_pos[i] = blend_position(acc_pos[i], s.position, w, layer.blend_mode)
      acc_rot[i] = blend_rotation(acc_rot[i], acc_w[i], s.rotation, w, layer.blend_mode)
      acc_scl[i] = blend_scale(acc_scl[i], s.scale, w, layer.blend_mode)
      acc_w[i] += w
    }
  }
  for i in 0 ..< n {
    if w := acc_w[i]; w > 0 {
      self.local[i] = {acc_pos[i] / w, linalg.normalize(acc_rot[i]), acc_scl[i] / w}
    } else {
      self.local[i] = skel.rest[i]
    }
  }
  pose_model(self, skel)
  // Procedural modifiers work on the skeleton-space pose
  moved := make([]bool, n, context.temp_allocator)
  any_moved := false
  for &layer in self.layers {
    if layer.weight <= 0 do continue
    pl := (&layer.data.(ProceduralLayer)) or_continue
    switch &m in pl.modifier {
    case TailModifier:
      tail_modifier_update(&m, pl.bone_indices, self.positions, self.rotations, skel.lengths, layer.weight, delta_time, root_world)
    case PathModifier:
      path_modifier_update(&m, pl.bone_indices, self.positions, self.rotations, skel.lengths, layer.weight, delta_time)
    case SpiderLegModifier:
      spider_leg_modifier_update(&m, pl.bone_indices, self.positions, self.rotations, skel.lengths, layer.weight, delta_time, root_world)
    }
    for b in pl.bone_indices do moved[b] = true
    any_moved = true
  }
  if any_moved do repropagate(self, skel, moved)
  // IK; WORLD-space targets are brought into skeleton space
  slice.fill(moved, false)
  any_moved = false
  root_inv := linalg.matrix4_inverse(root_world)
  for &layer in self.layers {
    if layer.weight <= 0 do continue
    target := layer.data.(IKTarget) or_continue
    if !target.enabled do continue
    target.weight = layer.weight
    if target.space == .WORLD {
      target.target_position = (root_inv * [4]f32{target.target_position.x, target.target_position.y, target.target_position.z, 1}).xyz
      target.pole_vector = (root_inv * [4]f32{target.pole_vector.x, target.pole_vector.y, target.pole_vector.z, 1}).xyz
    }
    fabrik_solve(self.positions, self.rotations, target)
    for b in target.bone_indices do moved[b] = true
    any_moved = true
  }
  if any_moved do repropagate(self, skel, moved)
  update_palette(self, skel)
  return self.palette
}

// Skeleton-space matrix of a bone in the current pose.
bone_matrix :: proc(self: ^Animator, bone: u32) -> matrix[4, 4]f32 {
  if int(bone) >= len(self.positions) do return linalg.MATRIX4F32_IDENTITY
  return linalg.matrix4_from_trs(self.positions[bone], self.rotations[bone], self.scales[bone])
}

// Parent→child bone link for skeleton visualization.
BoneSegment :: struct {
  from, to: [3]f32,
  depth:    u32,
}

// World-space bone segments of the current pose. Caller deletes.
bone_segments :: proc(
  self: ^Animator,
  skel: ^Skeleton,
  root_world: matrix[4, 4]f32,
  allocator := context.allocator,
) -> []BoneSegment {
  out := make([dynamic]BoneSegment, 0, len(self.positions), allocator)
  for p, i in skel.parents do if p >= 0 && int(p) < len(self.positions) && i < len(self.positions) {
    a := root_world * [4]f32{self.positions[p].x, self.positions[p].y, self.positions[p].z, 1}
    b := root_world * [4]f32{self.positions[i].x, self.positions[i].y, self.positions[i].z, 1}
    append(&out, BoneSegment{from = a.xyz, to = b.xyz, depth = skel.depths[p]})
  }
  return out[:]
}

// ---------- layer stack ----------

// Store `layer` at `index`, or append it when `index` is out of range.
@(private)
put_layer :: proc(self: ^Animator, layer: Layer, index: int) -> int {
  if index >= 0 && index < len(self.layers) {
    layer_destroy(&self.layers[index])
    self.layers[index] = layer
    return index
  }
  append(&self.layers, layer)
  return len(self.layers) - 1
}

@(private)
valid_layer :: #force_inline proc(self: ^Animator, index: int) -> bool {
  return index >= 0 && index < len(self.layers)
}

// Play clip `name` on layer 0, replacing whatever was there.
play :: proc(self: ^Animator, rig: ^Rig, name: string, mode: PlayMode = .LOOP, speed: f32 = 1) -> bool {
  _, ok := add_clip_layer(self, rig, name, 1, mode, speed, 0)
  return ok
}

// Add (or replace at `layer_index`) a layer playing clip `name`.
add_clip_layer :: proc(
  self: ^Animator,
  rig: ^Rig,
  name: string,
  weight: f32 = 1,
  mode: PlayMode = .LOOP,
  speed: f32 = 1,
  layer_index: int = -1,
  blend_mode: BlendMode = .REPLACE,
) -> (
  index: int,
  ok: bool,
) #optional_ok {
  clip := find_clip(rig, name) or_return
  return add_clip_layer_index(self, clip, weight, mode, speed, layer_index, blend_mode), true
}

// Clip layer by clip index (see find_clip); skips the name lookup.
add_clip_layer_index :: proc(
  self: ^Animator,
  clip: int,
  weight: f32 = 1,
  mode: PlayMode = .LOOP,
  speed: f32 = 1,
  layer_index: int = -1,
  blend_mode: BlendMode = .REPLACE,
) -> int {
  return put_layer(
    self,
    Layer {
      weight = weight,
      blend_mode = blend_mode,
      data = FKLayer{clip = clip, player = {mode = mode, speed = speed}},
    },
    layer_index,
  )
}

remove_layer :: proc(self: ^Animator, index: int) -> bool {
  if !valid_layer(self, index) do return false
  layer_destroy(&self.layers[index])
  ordered_remove(&self.layers, index)
  return true
}

clear_layers :: proc(self: ^Animator) {
  for &l in self.layers do layer_destroy(&l)
  clear(&self.layers)
  self.transition = {}
}

set_layer_weight :: proc(self: ^Animator, index: int, weight: f32) -> bool {
  if !valid_layer(self, index) do return false
  self.layers[index].weight = clamp(weight, 0, 1)
  return true
}

// `mask` is borrowed; it must outlive the layer.
set_layer_mask :: proc(self: ^Animator, index: int, mask: []bool) -> bool {
  if !valid_layer(self, index) do return false
  self.layers[index].bone_mask = mask
  return true
}

// Cross-fade from layer `from` to clip `name` played on layer `to`.
// self.transition.state becomes COMPLETE when the fade ends.
transition_to :: proc(
  self: ^Animator,
  rig: ^Rig,
  name: string,
  duration: f32,
  from: int = 0,
  to: int = 1,
  curve: ease.Ease = .Linear,
  blend_mode: BlendMode = .REPLACE,
  mode: PlayMode = .LOOP,
  speed: f32 = 1,
) -> bool {
  clip := find_clip(rig, name) or_return
  for len(self.layers) <= max(from, to) do append(&self.layers, Layer{})
  add_clip_layer_index(self, clip, 0, mode, speed, to, blend_mode)
  self.transition = {
    from_layer = from,
    to_layer   = to,
    duration   = duration,
    curve      = curve,
    state      = .ACTIVE,
  }
  return true
}

// ---------- IK ----------

// IK layer over `bones` (root first, ownership transfers to the layer).
// LOCAL targets are in skeleton space; WORLD targets are in world space and
// converted with `root_world` on every update.
add_ik_layer :: proc(
  self: ^Animator,
  rig: ^Rig,
  bones: []u32,
  target, pole: [3]f32,
  weight: f32 = 1,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  layer_index: int = -1,
  constraints: []IKBoneConstraint = nil,
  space: IKTargetSpace = .LOCAL,
) -> (
  index: int,
  ok: bool,
) #optional_ok {
  skel := &rig.skeleton
  if len(bones) < 2 do return -1, false
  for b in bones do if int(b) >= bone_count(skel) do return -1, false
  lengths := make([]f32, len(bones) - 1)
  for i in 0 ..< len(bones) - 1 do lengths[i] = skel.lengths[bones[i + 1]]
  layer := Layer {
    weight = weight,
    data = IKTarget {
      bone_indices = bones,
      bone_lengths = lengths,
      constraints = constraints,
      target_position = target,
      pole_vector = pole,
      max_iterations = max_iterations,
      tolerance = tolerance,
      weight = clamp(weight, 0, 1),
      enabled = true,
      space = space,
    },
  }
  return put_layer(self, layer, layer_index), true
}

// IK layer over the chain from `root_name` down to `tip_name`.
add_ik_chain_layer :: proc(
  self: ^Animator,
  rig: ^Rig,
  root_name, tip_name: string,
  target, pole: [3]f32,
  weight: f32 = 1,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  layer_index: int = -1,
  constraints: []IKBoneConstraint = nil,
  space: IKTargetSpace = .LOCAL,
) -> (
  index: int,
  ok: bool,
) #optional_ok {
  bones := bone_chain(&rig.skeleton, root_name, tip_name) or_return
  index, ok = add_ik_layer(self, rig, bones, target, pole, weight, max_iterations, tolerance, layer_index, constraints, space)
  if !ok do delete(bones)
  return
}

// Target and pole in the space the layer was created with.
set_ik_target :: proc(self: ^Animator, index: int, target, pole: [3]f32) -> bool {
  if !valid_layer(self, index) do return false
  ik := (&self.layers[index].data.(IKTarget)) or_return
  ik.target_position = target
  ik.pole_vector = pole
  return true
}

set_ik_enabled :: proc(self: ^Animator, index: int, enabled: bool) -> bool {
  if !valid_layer(self, index) do return false
  ik := (&self.layers[index].data.(IKTarget)) or_return
  ik.enabled = enabled
  return true
}

// ---------- procedural modifiers ----------

@(private)
modifier :: proc(self: ^Animator, index: int, $T: typeid) -> (m: ^T, ok: bool) {
  if !valid_layer(self, index) do return nil, false
  p := (&self.layers[index].data.(ProceduralLayer)) or_return
  return &p.modifier.(T)
}

add_tail_layer :: proc(
  self: ^Animator,
  rig: ^Rig,
  root_bone: string,
  length: u32,
  propagation_speed: f32 = 0.5,
  damping: f32 = 0.9,
  weight: f32 = 1,
  layer_index: int = -1,
  reverse_chain: bool = false, // root is at the tail end; reverse to head→tail
  stretch: bool = false, // bones may stretch; false = rigid hinge chain
) -> (
  index: int,
  ok: bool,
) #optional_ok {
  bones := bone_chain_down(&rig.skeleton, root_bone, length) or_return
  if reverse_chain do slice.reverse(bones)
  layer := Layer {
    weight = weight,
    data = ProceduralLayer {
      bone_indices = bones,
      modifier = TailModifier {
        propagation_speed = propagation_speed,
        damping = damping,
        stretch = stretch,
        bones = make([]TailBone, len(bones)),
      },
    },
  }
  return put_layer(self, layer, layer_index), true
}

set_tail_params :: proc(
  self: ^Animator,
  index: int,
  propagation_speed: Maybe(f32) = nil,
  damping: Maybe(f32) = nil,
  stretch: Maybe(bool) = nil,
) -> bool {
  m := modifier(self, index, TailModifier) or_return
  if v, ok := propagation_speed.?; ok do m.propagation_speed = v
  if v, ok := damping.?; ok do m.damping = v
  if v, ok := stretch.?; ok do m.stretch = v
  return true
}

@(private)
build_path_spline :: proc(path: [][3]f32, closed: bool) -> Spline([3]f32) {
  if closed && len(path) >= 3 do return spline_build_closed(path)
  times := make([]f32, len(path), context.temp_allocator)
  for i in 0 ..< len(times) do times[i] = f32(i)
  spline: Spline([3]f32)
  spline_init(&spline, path, times)
  return spline
}

add_path_layer :: proc(
  self: ^Animator,
  rig: ^Rig,
  root_bone: string,
  bone_length: u32,
  path: [][3]f32,
  offset: f32 = 0,
  length: f32 = 0, // path length the chain is fitted to (0 = offset to end)
  speed: f32 = 0,
  loop: bool = false,
  closed: bool = false, // build a closed-loop spline with a smooth seam
  weight: f32 = 1,
  layer_index: int = -1,
) -> (
  index: int,
  ok: bool,
) #optional_ok {
  if len(path) < 2 do return -1, false
  bones := bone_chain_down(&rig.skeleton, root_bone, bone_length) or_return
  layer := Layer {
    weight = weight,
    data = ProceduralLayer {
      bone_indices = bones,
      modifier = PathModifier {
        spline = build_path_spline(path, closed),
        offset = offset,
        length = length,
        speed = speed,
        loop = loop,
        closed = closed,
      },
    },
  }
  return put_layer(self, layer, layer_index), true
}

set_path_params :: proc(
  self: ^Animator,
  index: int,
  path: Maybe([][3]f32) = nil,
  offset: Maybe(f32) = nil,
  length: Maybe(f32) = nil,
  speed: Maybe(f32) = nil,
  loop: Maybe(bool) = nil,
  closed: Maybe(bool) = nil,
) -> bool {
  m := modifier(self, index, PathModifier) or_return
  if v, ok := closed.?; ok do m.closed = v
  if v, ok := path.?; ok && len(v) >= 2 {
    spline_destroy(&m.spline)
    m.spline = build_path_spline(v, m.closed)
  }
  if v, ok := offset.?; ok do m.offset = v
  if v, ok := length.?; ok do m.length = v
  if v, ok := speed.?; ok do m.speed = v
  if v, ok := loop.?; ok do m.loop = v
  return true
}

// Spider-leg layer, one leg per config. Each leg's chain starts at
// `config.root`; leg constraints transfer to the layer.
add_spider_leg_layer :: proc(
  self: ^Animator,
  rig: ^Rig,
  legs: []SpiderLegConfig,
  weight: f32 = 1,
  layer_index: int = -1,
) -> (
  index: int,
  ok: bool,
) #optional_ok {
  if len(legs) == 0 do return -1, false
  all_bones := make([dynamic]u32, 0, context.temp_allocator)
  out := make([]SpiderLeg, len(legs))
  for config, i in legs {
    chain, chain_ok := bone_chain_down(&rig.skeleton, config.root, config.chain_length, context.temp_allocator)
    if !chain_ok {
      delete(out)
      return -1, false
    }
    spider_leg_init(&out[i], config)
    out[i].chain_start = u32(len(all_bones))
    out[i].chain_length = u32(len(chain))
    append(&all_bones, ..chain)
  }
  layer := Layer {
    weight = weight,
    data = ProceduralLayer {
      bone_indices = slice.clone(all_bones[:]),
      modifier = SpiderLegModifier{legs = out},
    },
  }
  return put_layer(self, layer, layer_index), true
}

spider_leg_target :: proc(self: ^Animator, index, leg: int) -> (target: ^[3]f32, ok: bool) {
  m := modifier(self, index, SpiderLegModifier) or_return
  if leg < 0 || leg >= len(m.legs) do return nil, false
  return &m.legs[leg].target, true
}

set_spider_leg_params :: proc(
  self: ^Animator,
  index, leg: int,
  lift_height: Maybe(f32) = nil,
  lift_frequency: Maybe(f32) = nil,
  lift_duration: Maybe(f32) = nil,
  time_offset: Maybe(f32) = nil,
) -> bool {
  m := modifier(self, index, SpiderLegModifier) or_return
  if leg < 0 || leg >= len(m.legs) do return false
  l := &m.legs[leg]
  if v, ok := lift_height.?; ok do l.lift_height = v
  if v, ok := lift_frequency.?; ok do l.lift_frequency = v
  if v, ok := lift_duration.?; ok do l.lift_duration = v
  if v, ok := time_offset.?; ok do l.time_offset = v
  return true
}
