package animation

import "../geometry"
import "core:math"

// PathParams lays a chain along a path (set with path_points), fitted to `length` of it behind
// `offset`, moving `speed` units per second. Its layer's bones are the chain, head first: the head
// leads and the rest trail behind it.
PathParams :: struct {
  offset: f32, // where the chain's head starts along the path
  length: f32, // path length the chain is fitted to; 0 = from the path's start to offset
  speed:  f32,
  loop:   bool, // wrap around the path's end instead of stopping there
}

// Arc-length samples of a layer's path.
@(private = "file")
PATH_SAMPLES :: 200

// A path layer's state: [travelled, point count, closed, points (3 floats each), arc lengths,
// arc table's s].
@(private)
PATH_HEADER :: 3

@(private = "file")
path_arc :: proc(state: []f32) -> (arc: geometry.Arc([3]f32), ok: bool) {
  if len(state) <= PATH_HEADER do return {}, false
  n := int(state[1])
  p := PATH_HEADER
  arc.points = ([^][3]f32)(raw_data(state[p:]))[:n]
  arc.closed = state[2] != 0
  p += 3 * n
  arc.table = geometry.ArcTable {
    lengths = state[p:][:PATH_SAMPLES],
    at      = state[p + PATH_SAMPLES:][:PATH_SAMPLES],
  }
  return arc, true
}

// How many state floats a path through `count` points takes.
@(private)
path_state_size :: proc(count: int) -> int {
  return PATH_HEADER + 3 * count + 2 * PATH_SAMPLES
}

// Fill a path layer's state (sized by path_state_size) with an arc through `points`.
@(private)
path_fill :: proc(state: []f32, points: [][3]f32, closed: bool) {
  state[1] = f32(len(points))
  state[2] = 1 if closed else 0
  arc, _ := path_arc(state)
  copy(arc.points, points)
  table := arc.table.?
  geometry.arc_table_fill(arc, table.lengths, table.at)
}

@(private)
path_apply :: proc(pose: Pose, bones: []u32, state: []f32, params: PathParams, delta_time: f32) {
  n := len(bones)
  arc, ok := path_arc(state)
  if !ok do return
  total := geometry.arc_length(arc)
  if n < 2 || total <= 0 do return
  wrap :: proc(s, total: f32, loop: bool) -> f32 {
    return s - math.floor(s / total) * total if loop else clamp(s, 0, total)
  }
  // state[0] is how far the chain travelled; the head never runs past the end of an open path
  head := wrap(params.offset + state[0] + params.speed * delta_time, total, params.loop)
  state[0] = head - params.offset
  chain: f32 = 0
  for i in 1 ..< n do chain += pose.lengths[bones[i]]
  if chain <= 0 do return
  fit := params.length if params.length > 0 else head
  along: f32 = 0
  for b, i in bones {
    pose.positions[b] = geometry.arc_sample_uniform(arc, wrap(head - along / chain * fit, total, params.loop))
    if i < n - 1 do along += pose.lengths[bones[i + 1]]
  }
  for i in 0 ..< n - 1 do aim_bone(pose, bones[i], pose.positions[bones[i + 1]] - pose.positions[bones[i]])
  last := bones[n - 1]
  ahead := geometry.arc_sample_uniform(arc, wrap(head - fit - 0.01, total, params.loop))
  aim_bone(pose, last, ahead - pose.positions[last])
}
