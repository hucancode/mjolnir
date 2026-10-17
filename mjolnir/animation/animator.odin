package animation

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

// clip_find returns the clip named name.
clip_find :: proc(self: ^Rig, name: string) -> (clip: ClipHandle, ok: bool) #optional_ok {
  for c, i in self.clips do if c.name == name do return ClipHandle(i), true
  return 0, false
}

// Animator animates one instance of a rig with a stack of layers. Each update the clip
// layers blend the local pose, then the other layers edit the skeleton-space pose in
// priority order, each blended in by its weight. palette is the result a renderer uploads
// (skeleton-space bone matrix * inverse bind, per bone).
Animator :: struct {
  palette: []matrix[4, 4]f32,
  using _: Animator_State,
}

@(private)
Animator_State :: struct {
  // indexed by LayerHandle; a layer's bones and state are ranges of the pools below
  layers:    [dynamic]Layer,
  bones:     [dynamic]u32,
  state:     [dynamic]f32,
  // per bone, one allocation: the pose and the joint limits
  local:     []TRS,
  positions: [][3]f32,
  rotations: []quaternion128,
  scales:    [][3]f32,
  limits:    []JointLimit,
}

// animator_init allocates the pose for rig and sets it to its rest pose.
animator_init :: proc(self: ^Animator, rig: ^Rig) -> bool {
  skel := &rig.skeleton
  n := bone_count(skel)
  size := n * (size_of(matrix[4, 4]f32) + size_of(quaternion128) + 2 * size_of([3]f32) + size_of(TRS) + size_of(JointLimit))
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
  p += uintptr(n * size_of([3]f32))
  self.limits = ([^]JointLimit)(rawptr(p))[:n]
  slice.fill(self.limits, JOINT_FREE)
  copy(self.local, skel.rest)
  pose := pose_of(self, skel, linalg.MATRIX4F32_IDENTITY)
  for i in skel.order do compose_bone(pose, i)
  update_palette(self, skel)
  return true
}

// animator_destroy frees the animator's layers and pose.
animator_destroy :: proc(self: ^Animator) {
  delete(self.layers)
  delete(self.bones)
  delete(self.state)
  if len(self.palette) > 0 do mem.free(raw_data(self.palette))
  self^ = {}
}

@(private)
pose_of :: proc(self: ^Animator, skel: ^Skeleton, root_world: matrix[4, 4]f32) -> Pose {
  return {
    local = self.local,
    positions = self.positions,
    rotations = self.rotations,
    scales = self.scales,
    parents = skel.parents,
    order = skel.order,
    lengths = skel.lengths,
    limits = self.limits,
    root_world = root_world,
    root_inv = linalg.matrix4_inverse(root_world),
  }
}

@(private)
update_palette :: proc(self: ^Animator, skel: ^Skeleton) {
  for i in 0 ..< len(self.palette) {
    self.palette[i] = linalg.matrix4_from_trs(self.positions[i], self.rotations[i], self.scales[i]) * skel.inverse_bind[i]
  }
}

@(private)
range_of :: #force_inline proc(pool: []$T, r: Range) -> []T {
  return pool[r.start:][:r.count]
}

// animator_update advances every layer by `delta_time` and rebuilds the pose. `root_world` is
// the world matrix of the skinned object; WORLD-space IK targets, tails and legs use it.
// Returns the skinning palette (also in self.palette).
animator_update :: proc(
  self: ^Animator,
  rig: ^Rig,
  delta_time: f32,
  root_world: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) -> []matrix[4, 4]f32 {
  skel := &rig.skeleton
  n := bone_count(skel)
  if n == 0 || len(self.local) != n do return self.palette
  for &l in self.layers {
    if l.params == nil do continue
    fade_advance(&l, delta_time)
    c := l.params.(ClipParams) or_continue
    if int(c.clip) < len(rig.clips) do clip_advance(c, range_of(self.state[:], l.state), rig.clips[c.clip].duration, delta_time)
  }
  order := layer_order(self)
  // clip layers blend the local pose
  copy(self.local, skel.rest)
  acc_w := make([]f32, n, context.temp_allocator)
  for i in order {
    l := &self.layers[i]
    c := l.params.(ClipParams) or_continue
    if l.weight <= 0 || int(c.clip) >= len(rig.clips) do continue
    clip := &rig.clips[c.clip]
    t := self.state[l.state.start]
    bones := range_of(self.bones[:], l.bones)
    for k in 0 ..< (len(bones) if len(bones) > 0 else n) {
      b := int(bones[k]) if len(bones) > 0 else k
      s := skel.rest[b]
      clip_sample_trs(clip, b, t, &s)
      blend_sample(&self.local[b], &acc_w[b], s, skel.rest[b], l.weight, c.blend_mode)
    }
  }
  pose := pose_of(self, skel, root_world)
  for i in skel.order do compose_bone(pose, i)
  // the other layers edit the skeleton-space pose
  for i in order {
    l := &self.layers[i]
    if _, is_clip := l.params.(ClipParams); is_clip do continue
    layer_apply(pose, l, range_of(self.bones[:], l.bones), range_of(self.state[:], l.state), delta_time)
  }
  update_palette(self, skel)
  return self.palette
}

// Live layers by (priority, index).
@(private = "file")
layer_order :: proc(self: ^Animator) -> []u32 {
  keys := make([dynamic]u64, 0, len(self.layers), context.temp_allocator)
  // flipping the sign bit orders i32 priorities as u32
  for l, i in self.layers do if l.params != nil do append(&keys, u64(u32(l.priority) ~ 0x8000_0000) << 32 | u64(i))
  slice.sort(keys[:])
  order := make([]u32, len(keys), context.temp_allocator)
  for k, i in keys do order[i] = u32(k)
  return order
}

// Run one pose-editing layer at full strength, blend it in by its weight and move the
// descendants of its bones. A layer without state does nothing at weight 0; one with state
// keeps simulating so it is current when faded in.
@(private = "file")
layer_apply :: proc(pose: Pose, l: ^Layer, bones: []u32, state: []f32, delta_time: f32) {
  if l.weight <= 0 && len(state) == 0 do return
  positions := make([][3]f32, len(bones), context.temp_allocator)
  rotations := make([]quaternion128, len(bones), context.temp_allocator)
  for b, k in bones do positions[k], rotations[k] = pose.positions[b], pose.rotations[b]
  switch p in l.params {
  case ClipParams:
  case IKParams:
    ik_apply(pose, bones, p)
  case TailParams:
    tail_apply(pose, bones, state, p, delta_time, l.fresh)
  case PathParams:
    path_apply(pose, bones, state, p, delta_time)
  case LegParams:
    leg_apply(pose, bones, state, p, delta_time, l.fresh)
  case CustomParams:
    if p.apply != nil do p.apply(pose, bones, state, p.values, delta_time, l.fresh)
  }
  l.fresh = false
  pose_blend(pose, bones, positions, rotations, l.weight)
  moved := make([]bool, len(pose.parents), context.temp_allocator)
  for b in bones do moved[b] = true
  pose_propagate(pose, moved)
}

// A clip layer's state: [time, direction (1 or -1, PING_PONG turns it), stopped].
@(private)
clip_advance :: proc(params: ClipParams, state: []f32, duration, delta_time: f32) {
  player := ClipPlayer {
    time   = state[0],
    speed  = params.speed * state[1],
    status = .STOPPED if state[2] != 0 else .PLAYING,
    mode   = params.mode,
  }
  playback_advance(&player, duration, delta_time)
  state[0] = player.time
  state[1] = -1 if (player.speed < 0) != (params.speed < 0) else 1
  state[2] = 1 if player.status == .STOPPED else 0
}

// bone_matrix returns the skeleton-space matrix of a bone in the current pose.
bone_matrix :: proc(self: ^Animator, bone: u32) -> matrix[4, 4]f32 {
  if int(bone) >= len(self.positions) do return linalg.MATRIX4F32_IDENTITY
  return linalg.matrix4_from_trs(self.positions[bone], self.rotations[bone], self.scales[bone])
}

// bone_limits returns the joint limits IK and leg layers keep each bone within, indexed by
// bone; edit them in place. Every bone starts JOINT_FREE.
bone_limits :: proc(self: ^Animator) -> []JointLimit {
  return self.limits
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

@(private)
valid_layer :: #force_inline proc(self: ^Animator, layer: LayerHandle) -> bool {
  if int(layer.index) >= len(self.layers) do return false
  l := &self.layers[layer.index]
  return l.params != nil && l.generation == layer.generation
}

// layer_create adds a layer doing `params` to `bones` and returns its handle; it stays valid
// until layer_destroy or layers_clear.
//   ClipParams: bones it animates, nil = all
//   IKParams, LegParams: a chain, root first, each bone the parent of the next (bone_chain)
//   TailParams, PathParams: a chain of at least 2 bones, head first (bone_chain_down)
//   CustomParams: whatever its apply edits
// Layers run in priority order, lowest first, then by creation. The default puts clips (0)
// before tails, paths, legs and custom layers (100), and those before IK (200).
// Fails on an unknown clip, a bone out of range or a broken chain.
layer_create :: proc(
  self: ^Animator,
  rig: ^Rig,
  params: LayerParams,
  bones: []u32 = nil,
  weight: f32 = 1,
  priority: Maybe(i32) = nil,
) -> (
  handle: LayerHandle,
  ok: bool,
) #optional_ok {
  skel := &rig.skeleton
  for b in bones do if int(b) >= bone_count(skel) do return
  is_chain :: proc(skel: ^Skeleton, bones: []u32) -> bool {
    if len(bones) < 2 do return false
    for i in 1 ..< len(bones) do if skel.parents[bones[i]] != i32(bones[i - 1]) do return false
    return true
  }
  state := 0
  order: i32 = 100
  switch p in params {
  case ClipParams:
    if int(p.clip) >= len(rig.clips) do return
    state, order = 3, 0
  case IKParams:
    if !is_chain(skel, bones) do return
    order = 200
  case TailParams:
    if len(bones) < 2 do return
    state = TAIL_STATE * len(bones)
  case PathParams:
    if len(bones) < 2 do return
    state = PATH_HEADER
  case LegParams:
    if !is_chain(skel, bones) do return
    state = LEG_STATE
  case CustomParams:
    state = int(p.state)
  case:
    return
  }
  layer := Layer {
    weight   = clamp(weight, 0, 1),
    priority = priority.? or_else order,
    bones    = {u32(len(self.bones)), u32(len(bones))},
    state    = {u32(len(self.state)), u32(state)},
    fresh    = true,
    params   = params,
  }
  append(&self.bones, ..bones)
  resize(&self.state, len(self.state) + state)
  if _, is_clip := params.(ClipParams); is_clip do self.state[layer.state.start + 1] = 1
  for &l, i in self.layers do if l.params == nil {
    layer.generation = l.generation
    l = layer
    return {u32(i), l.generation}, true
  }
  layer.generation = 1
  append(&self.layers, layer)
  return {u32(len(self.layers) - 1), 1}, true
}

// layer_params returns the inputs of a layer of kind T, to edit in place; false when the
// layer is gone or of another kind.
layer_params :: proc(self: ^Animator, layer: LayerHandle, $T: typeid) -> (params: ^T, ok: bool) #optional_ok {
  if !valid_layer(self, layer) do return nil, false
  return &self.layers[layer.index].params.(T)
}

// layer_fade moves a layer's weight to `weight` (clamped to [0, 1]) over `duration` seconds
// along `curve`; 0 sets it at once. Cross-fade two layers by fading one out and one in.
layer_fade :: proc(
  self: ^Animator,
  layer: LayerHandle,
  weight: f32,
  duration: f32 = 0,
  curve: ease.Ease = .Linear,
) -> bool {
  if !valid_layer(self, layer) do return false
  l := &self.layers[layer.index]
  w := clamp(weight, 0, 1)
  if duration <= 0 {
    l.weight, l.fade = w, {}
  } else {
    l.fade = {from = l.weight, to = w, duration = duration, curve = curve}
  }
  return true
}

// layer_weight returns a layer's weight now (a fade moves it each update); 0 when gone.
layer_weight :: proc(self: ^Animator, layer: LayerHandle) -> f32 {
  return self.layers[layer.index].weight if valid_layer(self, layer) else 0
}

// Remove a range from the bones (`state` false) or state pool, closing the gap.
@(private = "file")
pool_remove :: proc(self: ^Animator, r: Range, state: bool) {
  if r.count == 0 do return
  if state {
    remove_range(&self.state, int(r.start), int(r.start + r.count))
  } else {
    remove_range(&self.bones, int(r.start), int(r.start + r.count))
  }
  for &l in self.layers {
    s := &l.state.start if state else &l.bones.start
    if s^ > r.start do s^ -= r.count
  }
}

// layer_destroy destroys a layer, leaving the other handles as they are; a stale handle is
// ignored.
layer_destroy :: proc(self: ^Animator, layer: LayerHandle) {
  if !valid_layer(self, layer) do return
  l := &self.layers[layer.index]
  bones, state := l.bones, l.state
  l^ = {generation = l.generation + 1}
  pool_remove(self, bones, false)
  pool_remove(self, state, true)
}

// layers_clear destroys every layer.
layers_clear :: proc(self: ^Animator) {
  for &l in self.layers do if l.params != nil do l = {generation = l.generation + 1}
  clear(&self.bones)
  clear(&self.state)
}

// play replaces the whole stack with clip `name` at full weight and returns its layer.
play :: proc(
  self: ^Animator,
  rig: ^Rig,
  name: string,
  mode: PlayMode = .LOOP,
  speed: f32 = 1,
) -> (
  layer: LayerHandle,
  ok: bool,
) #optional_ok {
  clip := clip_find(rig, name) or_return
  layers_clear(self)
  return layer_create(self, rig, ClipParams{clip = clip, speed = speed, mode = mode})
}

// clip_time returns where a clip layer is in its clip, in seconds; false if it is not a clip
// layer. A ONCE clip that ended holds its duration.
clip_time :: proc(self: ^Animator, layer: LayerHandle) -> (time: f32, ok: bool) #optional_ok {
  if !valid_layer(self, layer) do return 0, false
  l := &self.layers[layer.index]
  _ = l.params.(ClipParams) or_return
  return self.state[l.state.start], true
}

// clip_seek moves a clip layer to `time` seconds and plays it from there.
clip_seek :: proc(self: ^Animator, layer: LayerHandle, time: f32) -> bool {
  if !valid_layer(self, layer) do return false
  l := &self.layers[layer.index]
  _ = l.params.(ClipParams) or_return
  self.state[l.state.start] = time
  self.state[l.state.start + 2] = 0
  return true
}

// path_points sets the path of a path layer to a Catmull-Rom spline through `points` (copied),
// a loop when `closed` (needs 3 points). False if it is not a path layer or has < 2 points.
path_points :: proc(self: ^Animator, layer: LayerHandle, points: [][3]f32, closed := false) -> bool {
  if !valid_layer(self, layer) || len(points) < 2 do return false
  l := &self.layers[layer.index]
  _ = l.params.(PathParams) or_return
  closed := closed && len(points) >= 3
  travelled := self.state[l.state.start]
  pool_remove(self, l.state, true)
  size := path_state_size(len(points), closed)
  l.state = {u32(len(self.state)), u32(size)}
  resize(&self.state, len(self.state) + size)
  state := range_of(self.state[:], l.state)
  state[0] = travelled
  path_fill(state, points, closed)
  return true
}

// leg_foot returns where a leg layer's foot is, world space; false if it is not a leg layer.
leg_foot :: proc(self: ^Animator, layer: LayerHandle) -> (foot: [3]f32, ok: bool) #optional_ok {
  if !valid_layer(self, layer) do return {}, false
  l := &self.layers[layer.index]
  _ = l.params.(LegParams) or_return
  return leg_state(range_of(self.state[:], l.state)).foot, true
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
