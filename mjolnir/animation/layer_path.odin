package animation

import "core:math"

// PathParams lays a chain along a path (set with path_points), fitted to `length` of it from
// `offset` on, moving `speed` units per second. Its layer's bones are the chain, head first.
PathParams :: struct {
  offset: f32, // where the chain's head starts along the path
  length: f32, // path length the chain is fitted to; 0 = from offset to the end
  speed:  f32,
  loop:   bool, // wrap around the path's end instead of stopping there
}

// Arc-length samples of a layer's path.
@(private = "file")
PATH_SAMPLES :: 200

// A path layer's state: [travelled, point count, points (3 floats each), times, arc lengths,
// arc times].
@(private)
PATH_HEADER :: 2

@(private = "file")
path_spline :: proc(state: []f32) -> (spline: Spline([3]f32), ok: bool) {
  if len(state) <= PATH_HEADER do return {}, false
  n := int(state[1])
  p := PATH_HEADER
  spline.points = ([^][3]f32)(raw_data(state[p:]))[:n]
  p += 3 * n
  spline.times = state[p:][:n]
  p += n
  spline.arc_table = SplineArcTable([3]f32) {
    arc_lengths = state[p:][:PATH_SAMPLES],
    times       = state[p + PATH_SAMPLES:][:PATH_SAMPLES],
  }
  return spline, true
}

// How many state floats a path through `count` points takes.
@(private)
path_state_size :: proc(count: int, closed: bool) -> int {
  n := count + 3 if closed else count
  return PATH_HEADER + 4 * n + 2 * PATH_SAMPLES
}

// Fill a path layer's state (sized by path_state_size) with a spline through `points`.
@(private)
path_fill :: proc(state: []f32, points: [][3]f32, closed: bool) {
  n := len(points) + 3 if closed else len(points)
  state[1] = f32(n)
  spline, _ := path_spline(state)
  if closed {
    closed_points(points, spline.points, spline.times)
  } else {
    copy(spline.points, points)
    for &t, i in spline.times do t = f32(i)
  }
  table := spline.arc_table.?
  arc_fill(spline, table.arc_lengths, table.times, 0, f32(len(points)) if closed else f32(n - 1))
}

@(private)
path_apply :: proc(pose: Pose, bones: []u32, state: []f32, params: PathParams, delta_time: f32) {
  n := len(bones)
  spline, ok := path_spline(state)
  if !ok do return
  total := spline_arc_length(spline)
  if n < 2 || total <= 0 do return
  wrap :: proc(s, total: f32, loop: bool) -> f32 {
    return math.mod_f32(s, total) if loop else clamp(s, 0, total)
  }
  // state[0] is how far the chain travelled; the head never runs past the end of an open path
  head := wrap(params.offset + state[0] + params.speed * delta_time, total, params.loop)
  state[0] = head - params.offset
  chain: f32 = 0
  for i in 1 ..< n do chain += pose.lengths[bones[i]]
  if chain <= 0 do return
  fit := params.length if params.length > 0 else total - head
  along: f32 = 0
  for b, i in bones {
    pose.positions[b] = spline_sample_uniform(spline, wrap(head + along / chain * fit, total, params.loop))
    if i < n - 1 do along += pose.lengths[bones[i + 1]]
  }
  for i in 0 ..< n - 1 do aim_bone(pose, bones[i], pose.positions[bones[i + 1]] - pose.positions[bones[i]])
  last := bones[n - 1]
  ahead := spline_sample_uniform(spline, wrap(head + fit + 0.01, total, params.loop))
  aim_bone(pose, last, ahead - pose.positions[last])
}
