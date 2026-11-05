package geometry

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:slice"

// Arc is a smooth path through its points: a foot's step, a camera's track, a snake's loop. It runs
// from s = 0 at its first point to s = 1 at its end (its last point; closed, its first again).
//   - `knots`: where along it (s) each point is, rising; nil spreads them evenly, point k at
//     k / segments (n - 1 open, n closed). A closed arc's last knot is below its first plus 1, room
//     for the way back. Knots time the path, not its shape: moving one changes when the arc passes
//     its point, not where it goes.
//   - `sharp`: which points are corners, one per point; nil for none. Between two corners the arc
//     is a straight line run at a steady speed (a foot on the ground, a piston's stroke).
//   - `closed`: it runs on from its last point back to its first (a loop), each point written once.
// Between its points it is a cubic (Hermite), each point's tangent half the way from the point
// before it to the one after (Catmull-Rom), or the segment's own chord at a corner or an open arc's
// end. Past its ends an open arc runs on along its end tangents; a closed one goes round again.
// `table` (arc_table_fill) maps distance along it to s, for sampling at a steady speed.
// An Arc is a view: fill one over arrays of your own, or arc_init copies them into its own.
Arc :: struct($T: typeid) {
  points: []T,
  knots:  []f32,
  sharp:  []bool,
  closed: bool,
  table:  Maybe(ArcTable),
}

// ArcTable is an arc's length at evenly spaced s (`lengths`, rising from 0, at `at`), for
// arc_sample_uniform.
ArcTable :: struct {
  lengths, at: []f32,
}

// arc_init copies `points` (and `knots`, `sharp`, when given) into an arc of its own. Fails without
// allocating on fewer than 2 points, or knots or corners not one per point, or knots not rising. A
// vector arc also gets a table of `samples` entries (arc_sample_uniform). Free with arc_destroy.
arc_init :: proc(self: ^Arc($T), points: []T, knots: []f32 = nil, sharp: []bool = nil, closed := false, samples := 200) -> bool {
  n := len(points)
  if n < 2 do return false
  if knots != nil && (len(knots) != n || !slice.is_sorted(knots)) do return false
  if sharp != nil && len(sharp) != n do return false
  self^ = {points = slice.clone(points), closed = closed}
  if knots != nil do self.knots = slice.clone(knots)
  if sharp != nil do self.sharp = slice.clone(sharp)
  when intrinsics.type_is_array(T) {
    table := ArcTable{make([]f32, max(samples, 2)), make([]f32, max(samples, 2))}
    arc_table_fill(self^, table.lengths, table.at)
    self.table = table
  }
  return true
}

// arc_destroy frees what arc_init made.
arc_destroy :: proc(self: ^Arc($T)) {
  delete(self.points)
  delete(self.knots)
  delete(self.sharp)
  if table, ok := self.table.?; ok {
    delete(table.lengths)
    delete(table.at)
  }
  self^ = {}
}

// arc_segments is how many segments `arc` has: n - 1 open, n closed (a closed arc needs 3 points).
arc_segments :: proc(arc: Arc($T)) -> int {
  n := len(arc.points)
  return n if arc.closed && n > 2 else n - 1
}

// arc_knot is where along `arc` point i is (Arc.knots; evenly spread with none, or not one per
// point); i = n is a closed arc's first point again, a pass on.
arc_knot :: proc(arc: Arc($T), i: int) -> f32 {
  n := len(arc.points)
  if len(arc.knots) != n do return f32(i) / f32(max(arc_segments(arc), 1))
  return arc.knots[i] if i < n else arc.knots[0] + 1
}

// arc_sample is `arc` at `s` (Arc).
arc_sample :: proc(arc: Arc($T), s: f32) -> T {
  points := arc.points
  n := len(points)
  if n == 0 do return T{}
  if n == 1 do return points[0]
  closed := arc.closed && n > 2
  segments := arc_segments(arc)
  first := arc_knot(arc, 0)
  u := s
  if closed do u = first + (s - first) - math.floor(s - first)
  // the segment u is in: the last whose start is at or before it (the first before the arc)
  k := 0
  for i in 1 ..< segments do if arc_knot(arc, i) <= u do k = i
  u0, u1 := arc_knot(arc, k), arc_knot(arc, k + 1)
  t := (u - u0) / (u1 - u0) if u1 - u0 > 1e-6 else (0 if u < u1 else 1)
  at :: proc(points: []$T, i: int) -> T {return points[(i + len(points)) % len(points)]}
  // the tangent at point i: Catmull-Rom's, or the chord at an end or a corner
  tangent :: proc(points: []$T, sharp: []bool, i: int, closed: bool, chord: T) -> T {
    n := len(points)
    if len(sharp) >= n && sharp[(i + n) % n] do return chord
    if !closed && (i == 0 || i == n - 1) do return chord
    return (at(points, i + 1) - at(points, i - 1)) / 2
  }
  p1, p2 := at(points, k), at(points, k + 1)
  chord := p2 - p1
  m1, m2 := tangent(points, arc.sharp, k, closed, chord), tangent(points, arc.sharp, k + 1, closed, chord)
  if t < 0 do return p1 + m1 * t
  if t > 1 do return p2 + m2 * (t - 1)
  t2, t3 := t * t, t * t * t
  return (2 * t3 - 3 * t2 + 1) * p1 + (t3 - 2 * t2 + t) * m1 + (3 * t2 - 2 * t3) * p2 + (t3 - t2) * m2
}

// arc_table_fill fills a table of caller memory (one entry per sample, `lengths` and `at` alike)
// for `arc`, from its first point to its end: arc.table = ArcTable{lengths, at}.
arc_table_fill :: proc(arc: Arc($T), lengths, at: []f32) {
  samples := len(lengths)
  if samples == 0 do return
  from, to := arc_knot(arc, 0), arc_knot(arc, arc_segments(arc))
  prev := arc_sample(arc, from)
  total: f32 = 0
  for i in 0 ..< samples {
    s := from + (to - from) * f32(i) / f32(max(samples - 1, 1))
    p := arc_sample(arc, s)
    when intrinsics.type_is_array(T) {
      total += linalg.distance(p, prev)
    } else {
      total += abs(p - prev)
    }
    lengths[i], at[i] = total, s
    prev = p
  }
}

// arc_sample_uniform is `arc` at `distance` along it, within its ends (Arc.table); with no table,
// `distance` is taken as s.
arc_sample_uniform :: proc(arc: Arc($T), distance: f32) -> T {
  table, ok := arc.table.?
  if !ok do return arc_sample(arc, distance)
  n := len(table.lengths)
  if n == 0 do return T{}
  if math.is_nan(distance) || distance <= table.lengths[0] do return arc_sample(arc, table.at[0])
  if distance >= table.lengths[n - 1] do return arc_sample(arc, table.at[n - 1])
  cmp :: proc(item: f32, d: f32) -> slice.Ordering {return .Less if item < d else .Greater}
  i, _ := slice.binary_search_by(table.lengths, distance, cmp)
  i -= 1
  span := table.lengths[i + 1] - table.lengths[i]
  k := (distance - table.lengths[i]) / span if span > 0 else 0
  return arc_sample(arc, table.at[i] + k * (table.at[i + 1] - table.at[i]))
}

// arc_length is how long `arc` is (its table's); 0 with no table.
arc_length :: proc(arc: Arc($T)) -> f32 {
  table, ok := arc.table.?
  if !ok || len(table.lengths) == 0 do return 0
  return table.lengths[len(table.lengths) - 1]
}
