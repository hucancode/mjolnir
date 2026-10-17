package animation

import "../geometry"
import "core:math/ease"
import "core:math/linalg"
import "core:mem"
import "core:slice"

// Rig is a skeleton plus the clips authored for it. Asset data, shared by every
// Animator that plays it.
Rig :: struct {
  skeleton: Skeleton,
  clips:    [dynamic]Clip,
}

// rig_destroy frees the rig's skeleton and clips.
rig_destroy :: proc(self: ^Rig) {
  skeleton_destroy(&self.skeleton)
  for &c in self.clips do clip_destroy(&c)
  delete(self.clips)
  self^ = {}
}

// find_clip returns the clip named name.
find_clip :: proc(self: ^Rig, name: string) -> (clip: ClipHandle, ok: bool) #optional_ok {
  for c, i in self.clips do if c.name == name do return ClipHandle(i), true
  return 0, false
}

// Animator is the per-instance animation state of one skeleton. Owns its layer stack and the
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

// animator_init allocates the pose arrays for rig and sets them to its rest pose.
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

// animator_destroy frees the animator's layers and pose storage.
animator_destroy :: proc(self: ^Animator) {
  for &l in self.layers do layer_free(&l)
  delete(self.layers)
  if len(self.palette) > 0 do mem.free(raw_data(self.palette))
  self^ = {}
}

@(private)
layer_free :: proc(self: ^Layer) {
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

// animator_update advances every layer by `delta_time` and rebuilds the pose. `root_world` is the
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
    if int(fk.clip) >= len(rig.clips) do continue
    playback_advance(fk, rig.clips[fk.clip].duration, delta_time)
  }
  copy(self.local, skel.rest)
  acc_w := make([]f32, n, context.temp_allocator)
  for &layer in self.layers {
    if layer.weight <= 0 do continue
    fk := layer.data.(FKLayer) or_continue
    if int(fk.clip) >= len(rig.clips) do continue
    clip := &rig.clips[fk.clip]
    mask, has_mask := layer.bone_mask.?
    for i in 0 ..< n {
      if has_mask && (i >= len(mask) || !mask[i]) do continue
      s := skel.rest[i]
      clip_sample_trs(clip, i, fk.time, &s)
      blend_sample(&self.local[i], &acc_w[i], s, skel.rest[i], layer.weight, layer.blend_mode)
    }
  }
  pose_model(self, skel)
  moved := make([]bool, n, context.temp_allocator)
  any_moved := false
  // Procedural layers run before IK regardless of layer order. They simulate
  // at weight 0 too so spring and stepping state stay current.
  for &layer in self.layers {
    pl := (&layer.data.(ProceduralLayer)) or_continue
    switch &m in pl.modifier {
    case TailModifier:
      tail_modifier_update(&m, pl.bone_indices, self.positions, self.rotations, skel.lengths, layer.weight, delta_time, root_world)
    case PathModifier:
      path_modifier_update(&m, pl.bone_indices, self.positions, self.rotations, skel.lengths, layer.weight, delta_time)
    case SpiderLegModifier:
      spider_leg_modifier_update(&m, pl.bone_indices, self.positions, self.rotations, skel.lengths, layer.weight, delta_time, root_world)
    }
    if layer.weight <= 0 do continue
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

// bone_matrix returns the skeleton-space matrix of a bone in the current pose.
bone_matrix :: proc(self: ^Animator, bone: u32) -> matrix[4, 4]f32 {
  if int(bone) >= len(self.positions) do return linalg.MATRIX4F32_IDENTITY
  return linalg.matrix4_from_trs(self.positions[bone], self.rotations[bone], self.scales[bone])
}

// BoneSegment is a parent-to-child bone link for skeleton visualization.
BoneSegment :: struct {
  from, to: [3]f32,
  depth:    u32,
}

// bone_segments returns the world-space bone segments of the current pose. Caller deletes.
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

// Store `layer` in place of `replace` if it is a layer, else in the first empty slot or appended.
@(private)
put_layer :: proc(self: ^Animator, layer: Layer, replace: Maybe(LayerHandle)) -> LayerHandle {
  if r, ok := replace.?; ok && int(r) < len(self.layers) {
    layer_free(&self.layers[r])
    self.layers[r] = layer
    return r
  }
  for &l, i in self.layers do if l.data == nil {
    l = layer
    return LayerHandle(i)
  }
  append(&self.layers, layer)
  return LayerHandle(len(self.layers) - 1)
}

@(private)
valid_layer :: #force_inline proc(self: ^Animator, layer: LayerHandle) -> bool {
  return int(layer) < len(self.layers) && self.layers[layer].data != nil
}

// play plays clip `name` on layer 0, replacing whatever was there.
play :: proc(self: ^Animator, rig: ^Rig, name: string, mode: PlayMode = .LOOP, speed: f32 = 1) -> bool {
  _, ok := clip_layer_create(self, rig, name, 1, mode, speed, LayerHandle(0))
  return ok
}

// clip_layer_create adds a layer playing clip `name`, or puts it in place of layer `replace`. A
// LayerHandle stays valid until layer_destroy or clear_layers; a freed one may be handed out again.
clip_layer_create :: proc(
  self: ^Animator,
  rig: ^Rig,
  name: string,
  weight: f32 = 1,
  mode: PlayMode = .LOOP,
  speed: f32 = 1,
  replace: Maybe(LayerHandle) = nil,
  blend_mode: BlendMode = .REPLACE,
) -> (
  handle: LayerHandle,
  ok: bool,
) #optional_ok {
  clip := find_clip(rig, name) or_return
  return put_clip_layer(self, clip, weight, mode, speed, replace, blend_mode), true
}

@(private)
put_clip_layer :: proc(
  self: ^Animator,
  clip: ClipHandle,
  weight: f32 = 1,
  mode: PlayMode = .LOOP,
  speed: f32 = 1,
  replace: Maybe(LayerHandle) = nil,
  blend_mode: BlendMode = .REPLACE,
) -> LayerHandle {
  return put_layer(
    self,
    Layer {
      weight = weight,
      blend_mode = blend_mode,
      data = FKLayer{clip = clip, player = {mode = mode, speed = speed}},
    },
    replace,
  )
}

// layer_destroy destroys the layer at index, leaving the other indices as they are; false if
// index is invalid.
layer_destroy :: proc(self: ^Animator, layer: LayerHandle) -> bool {
  if !valid_layer(self, layer) do return false
  layer_free(&self.layers[layer])
  return true
}

// clear_layers destroys every layer and cancels any transition.
clear_layers :: proc(self: ^Animator) {
  for &l in self.layers do layer_free(&l)
  clear(&self.layers)
  self.transition = {}
}

// set_layer_weight sets the blend weight of the layer at index, clamped to [0, 1].
set_layer_weight :: proc(self: ^Animator, layer: LayerHandle, weight: f32) -> bool {
  if !valid_layer(self, layer) do return false
  self.layers[layer].weight = clamp(weight, 0, 1)
  return true
}

// set_layer_mask restricts the layer to the bones enabled in `mask`, which is borrowed and must outlive the layer.
set_layer_mask :: proc(self: ^Animator, layer: LayerHandle, mask: []bool) -> bool {
  if !valid_layer(self, layer) do return false
  self.layers[layer].bone_mask = mask
  return true
}

// transition_to cross-fades from layer `from` to clip `name` played on layer `to`.
// self.transition.state becomes COMPLETE when the fade ends.
transition_to :: proc(
  self: ^Animator,
  rig: ^Rig,
  name: string,
  duration: f32,
  from: LayerHandle = 0,
  to: LayerHandle = 1,
  curve: ease.Ease = .Linear,
  blend_mode: BlendMode = .REPLACE,
  mode: PlayMode = .LOOP,
  speed: f32 = 1,
) -> bool {
  clip := find_clip(rig, name) or_return
  for len(self.layers) <= int(max(from, to)) do append(&self.layers, Layer{})
  put_clip_layer(self, clip, 0, mode, speed, to, blend_mode)
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

// ik_layer_create adds an IK layer over `bones` (root first, each bone the parent of the next, as
// bone_chain returns; ownership transfers to the layer, or stays with the caller on failure). `constraints` is nil or one per bone.
// LOCAL targets are in skeleton space; WORLD targets are in world space and
// converted with `root_world` on every update. The layer weight blends FK (0) to IK (1).
ik_layer_create :: proc(
  self: ^Animator,
  rig: ^Rig,
  bones: []u32,
  target, pole: [3]f32,
  weight: f32 = 1,
  max_iterations: int = 10,
  tolerance: f32 = 0.001,
  replace: Maybe(LayerHandle) = nil,
  constraints: []IKBoneConstraint = nil,
  space: IKTargetSpace = .LOCAL,
  pole_weight: f32 = 1,
) -> (
  handle: LayerHandle,
  ok: bool,
) #optional_ok {
  skel := &rig.skeleton
  if len(bones) < 2 do return 0, false
  if constraints != nil && len(constraints) != len(bones) do return 0, false
  for b in bones do if int(b) >= bone_count(skel) do return 0, false
  for i in 1 ..< len(bones) do if skel.parents[bones[i]] != i32(bones[i - 1]) do return 0, false
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
      pole_weight = clamp(pole_weight, 0, 1),
      max_iterations = max_iterations,
      tolerance = tolerance,
      weight = clamp(weight, 0, 1),
      enabled = true,
      space = space,
    },
  }
  return put_layer(self, layer, replace), true
}

// set_ik_target sets target and pole in the space the layer was created with.
set_ik_target :: proc(self: ^Animator, layer: LayerHandle, target, pole: [3]f32) -> bool {
  if !valid_layer(self, layer) do return false
  ik := (&self.layers[layer].data.(IKTarget)) or_return
  ik.target_position = target
  ik.pole_vector = pole
  return true
}

// set_ik_enabled switches the IK layer at index on or off; false if it is not an IK layer.
set_ik_enabled :: proc(self: ^Animator, layer: LayerHandle, enabled: bool) -> bool {
  if !valid_layer(self, layer) do return false
  ik := (&self.layers[layer].data.(IKTarget)) or_return
  ik.enabled = enabled
  return true
}

// ---------- procedural modifiers ----------

@(private)
modifier :: proc(self: ^Animator, layer: LayerHandle, $T: typeid) -> (m: ^T, ok: bool) {
  if !valid_layer(self, layer) do return nil, false
  p := (&self.layers[layer].data.(ProceduralLayer)) or_return
  return &p.modifier.(T)
}

// tail_layer_create adds a spring-driven tail over length bones starting at root_bone.
tail_layer_create :: proc(
  self: ^Animator,
  rig: ^Rig,
  root_bone: string,
  length: u32,
  propagation_speed: f32 = 0.5,
  damping: f32 = 0.9,
  weight: f32 = 1,
  replace: Maybe(LayerHandle) = nil,
  reverse_chain: bool = false, // root is at the tail end; reverse to head→tail
  stretch: bool = false, // bones may stretch; false = rigid hinge chain
) -> (
  handle: LayerHandle,
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
  return put_layer(self, layer, replace), true
}

// set_tail_params updates the tail layer at index; nil arguments are left unchanged.
set_tail_params :: proc(
  self: ^Animator,
  layer: LayerHandle,
  propagation_speed: Maybe(f32) = nil,
  damping: Maybe(f32) = nil,
  stretch: Maybe(bool) = nil,
) -> bool {
  m := modifier(self, layer, TailModifier) or_return
  if v, ok := propagation_speed.?; ok do m.propagation_speed = v
  if v, ok := damping.?; ok do m.damping = v
  if v, ok := stretch.?; ok do m.stretch = v
  return true
}

@(private)
build_path_spline :: proc(path: [][3]f32, closed: bool) -> Spline([3]f32) {
  if closed && len(path) >= 3 do return spline_create_closed(path)
  times := make([]f32, len(path), context.temp_allocator)
  for i in 0 ..< len(times) do times[i] = f32(i)
  spline: Spline([3]f32)
  spline_init(&spline, path, times)
  return spline
}

// path_layer_create adds a layer that moves a bone_length-bone chain from root_bone along path.
path_layer_create :: proc(
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
  replace: Maybe(LayerHandle) = nil,
) -> (
  handle: LayerHandle,
  ok: bool,
) #optional_ok {
  if len(path) < 2 do return 0, false
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
  return put_layer(self, layer, replace), true
}

// set_path_params updates the path layer at index; nil arguments are left unchanged.
set_path_params :: proc(
  self: ^Animator,
  layer: LayerHandle,
  path: Maybe([][3]f32) = nil,
  offset: Maybe(f32) = nil,
  length: Maybe(f32) = nil,
  speed: Maybe(f32) = nil,
  loop: Maybe(bool) = nil,
  closed: Maybe(bool) = nil,
) -> bool {
  m := modifier(self, layer, PathModifier) or_return
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

// spider_leg_layer_create adds a layer with one leg per config. Each leg's chain starts at
// `config.root`; leg constraints transfer to the layer.
spider_leg_layer_create :: proc(
  self: ^Animator,
  rig: ^Rig,
  legs: []SpiderLegConfig,
  weight: f32 = 1,
  replace: Maybe(LayerHandle) = nil,
) -> (
  handle: LayerHandle,
  ok: bool,
) #optional_ok {
  if len(legs) == 0 do return 0, false
  all_bones := make([dynamic]u32, 0, context.temp_allocator)
  out := make([]SpiderLeg, len(legs))
  for config, i in legs {
    chain, chain_ok := bone_chain_down(&rig.skeleton, config.root, config.chain_length, context.temp_allocator)
    if !chain_ok {
      delete(out)
      return 0, false
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
  return put_layer(self, layer, replace), true
}

// spider_leg_target returns a pointer to the foot target of a leg so the caller can move it.
spider_leg_target :: proc(self: ^Animator, layer: LayerHandle, leg: int) -> (target: ^[3]f32, ok: bool) {
  m := modifier(self, layer, SpiderLegModifier) or_return
  if leg < 0 || leg >= len(m.legs) do return nil, false
  return &m.legs[leg].target, true
}

// set_spider_leg_params updates one leg's stepping parameters; nil arguments are left unchanged.
set_spider_leg_params :: proc(
  self: ^Animator,
  layer: LayerHandle,
  leg: int,
  lift_height: Maybe(f32) = nil,
  lift_frequency: Maybe(f32) = nil,
  lift_duration: Maybe(f32) = nil,
  time_offset: Maybe(f32) = nil,
) -> bool {
  m := modifier(self, layer, SpiderLegModifier) or_return
  if leg < 0 || leg >= len(m.legs) do return false
  l := &m.legs[leg]
  if v, ok := lift_height.?; ok do l.lift_height = v
  if v, ok := lift_frequency.?; ok do l.lift_frequency = v
  if v, ok := lift_duration.?; ok do l.lift_duration = v
  if v, ok := time_offset.?; ok do l.time_offset = v
  return true
}

// destroy frees an animator, rig, skeleton, clip or spline, or an animator's layer, as its *_destroy does.
destroy :: proc {
  animator_destroy,
  rig_destroy,
  skeleton_destroy,
  clip_destroy,
  spline_destroy,
  layer_destroy,
}
