package animation

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:slice"

// Spline is a Catmull-Rom cubic spline for smooth interpolation through control points
// Automatically generates tangents using neighboring points
Spline :: struct($T: typeid) {
  points:    []T,
  times:     []f32,
  arc_table: Maybe(Spline_Arc_Length_Table(T)), // Optional arc-length table for uniform sampling
}

// spline_init copies `points` and their key `times` into a spline. Fails without
// allocating unless there are at least 2 points, one time per point, and the
// times are non-decreasing. Vector splines also get an arc-length table of
// `samples` entries for spline_sample_uniform. Free with spline_destroy.
spline_init :: proc(self: ^Spline($T), points: []T, times: []f32, samples := 200) -> bool {
  if len(points) < 2 || len(points) != len(times) || !slice.is_sorted(times) do return false
  self^ = {points = slice.clone(points), times = slice.clone(times)}
  when intrinsics.type_is_array(T) do spline_build_arc_table(self, max(samples, 2))
  return true
}

@(private)
spline_create :: proc($T: typeid, count: int) -> Spline(T) {
  return Spline(T){points = make([]T, count), times = make([]f32, count)}
}

// spline_destroy frees the spline's points, times and arc-length table.
spline_destroy :: proc(self: ^Spline($T)) {
  delete(self.points)
  delete(self.times)
  if table, ok := self.arc_table.?; ok {
    delete(table.arc_lengths)
    delete(table.times)
  }
}

@(private)
spline_validate :: proc(spline: Spline($T)) -> bool {
  return slice.is_sorted(spline.times)
}

// Cubic Hermite basis functions.
@(private)
hermite_h00 :: proc "contextless" (t: f32) -> f32 {
  return 2 * t * t * t - 3 * t * t + 1
}

@(private)
hermite_h10 :: proc "contextless" (t: f32) -> f32 {
  return t * t * t - 2 * t * t + t
}

@(private)
hermite_h01 :: proc "contextless" (t: f32) -> f32 {
  return -2 * t * t * t + 3 * t * t
}

@(private)
hermite_h11 :: proc "contextless" (t: f32) -> f32 {
  return t * t * t - t * t
}

// Catmull-Rom tangent calculation: m_i = (p_{i+1} - p_{i-1}) / 2
@(private)
catmull_rom_tangent :: proc "contextless" (p_prev: $T, p_next: T) -> T {
  return (p_next - p_prev) * 0.5
}

// spline_sample evaluates the spline at time t, clamped to its first and last key.
spline_sample :: proc(spline: Spline($T), t: f32) -> T {
  n := len(spline.points)
  if n == 0 {
    return T{}
  }
  if n == 1 {
    return slice.first(spline.points)
  }
  if t <= slice.first(spline.times) {
    return slice.first(spline.points)
  }
  if t >= slice.last(spline.times) {
    return slice.last(spline.points)
  }

  // Returns the index where t would be inserted (first element > t)
  cmp :: proc(item: f32, t: f32) -> slice.Ordering {
    return slice.Ordering.Less if item < t else slice.Ordering.Greater
  }
  idx, _ := slice.binary_search_by(spline.times, t, cmp)
  // binary_search returns insertion point, we need the segment before it
  i := idx - 1

  p0 := spline.points[i]
  p1 := spline.points[i + 1]
  t0 := spline.times[i]
  t1 := spline.times[i + 1]

  u := (t - t0) / (t1 - t0)

  // For endpoints, duplicate the endpoint or use zero tangent
  m0: T
  m1: T

  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    // For quaternions, use simple difference (will be normalized later)
    if i == 0 {
      m0 = p1 - p0
    } else {
      m0 = catmull_rom_tangent(spline.points[i - 1], p1)
    }

    if i == n - 2 {
      m1 = p1 - p0
    } else {
      m1 = catmull_rom_tangent(p0, spline.points[i + 2])
    }

    dt := t1 - t0
    m0_scaled := quaternion(
      x = m0.x * dt,
      y = m0.y * dt,
      z = m0.z * dt,
      w = m0.w * dt,
    )
    m1_scaled := quaternion(
      x = m1.x * dt,
      y = m1.y * dt,
      z = m1.z * dt,
      w = m1.w * dt,
    )

    h00 := hermite_h00(u)
    h10 := hermite_h10(u)
    h01 := hermite_h01(u)
    h11 := hermite_h11(u)

    return linalg.normalize(
      quaternion(
        x = h00 * p0.x + h10 * m0_scaled.x + h01 * p1.x + h11 * m1_scaled.x,
        y = h00 * p0.y + h10 * m0_scaled.y + h01 * p1.y + h11 * m1_scaled.y,
        z = h00 * p0.z + h10 * m0_scaled.z + h01 * p1.z + h11 * m1_scaled.z,
        w = h00 * p0.w + h10 * m0_scaled.w + h01 * p1.w + h11 * m1_scaled.w,
      ),
    )
  } else {
    if i == 0 {
      m0 = p1 - p0
    } else {
      m0 = catmull_rom_tangent(spline.points[i - 1], p1)
    }

    if i == n - 2 {
      m1 = p1 - p0
    } else {
      m1 = catmull_rom_tangent(p0, spline.points[i + 2])
    }

    dt := t1 - t0
    m0 *= dt
    m1 *= dt

    h00 := hermite_h00(u)
    h10 := hermite_h10(u)
    h01 := hermite_h01(u)
    h11 := hermite_h11(u)

    return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
  }
}

// spline_duration returns the time between the first and last key.
spline_duration :: proc(spline: Spline($T)) -> f32 {
  if len(spline.times) == 0 {
    return 0
  }
  return slice.last(spline.times) - slice.first(spline.times)
}

// Spline_Arc_Length_Table is an arc-length lookup table for uniform spatial sampling.
Spline_Arc_Length_Table :: struct($T: typeid) {
  arc_lengths: []f32, // Cumulative arc-lengths at sample points
  times:       []f32, // Corresponding time values
}

@(private)
spline_build_arc_table :: proc(self: ^Spline($T), samples := 200) {
  // samples: Number of samples for approximation (more = accurate but slower)
  if len(self.times) == 0 do return
  table := Spline_Arc_Length_Table(T) {
    arc_lengths = make([]f32, samples),
    times       = make([]f32, samples),
  }
  arc_fill(self^, table.arc_lengths, table.times, slice.first(self.times), slice.last(self.times))
  self.arc_table = table
}

// Fill an arc-length table (one entry per sample) over spline times [t_start, t_end].
@(private)
arc_fill :: proc(spline: Spline($T), arc_lengths, times: []f32, t_start, t_end: f32) {
  samples := len(arc_lengths)
  prev := spline_sample(spline, t_start)
  total := f32(0)
  for i in 0 ..< samples {
    t := t_start + f32(i) * (t_end - t_start) / f32(samples - 1)
    pos := spline_sample(spline, t)
    if i > 0 do total += linalg.distance(pos, prev)
    arc_lengths[i] = total
    times[i] = t
    prev = pos
  }
}

// spline_sample_uniform evaluates the spline at arc length s; without an arc table s is treated as time.
spline_sample_uniform :: proc(spline: Spline($T), s: f32) -> T {
  // s: Arc-length parameter [0, total_length]
  table, ok := spline.arc_table.?
  if !ok do return spline_sample(spline, s)
  n := len(table.arc_lengths)
  if n == 0 do return T{}
  if math.is_nan(s) || s <= table.arc_lengths[0] do return spline_sample(spline, table.times[0])
  total := table.arc_lengths[n - 1]
  if s >= total do return spline_sample(spline, table.times[n - 1])
  cmp :: proc(item: f32, s: f32) -> slice.Ordering {
    return .Less if item < s else .Greater
  }
  idx, _ := slice.binary_search_by(table.arc_lengths, s, cmp)
  i := idx - 1
  u :=
    (s - table.arc_lengths[i]) /
    (table.arc_lengths[i + 1] - table.arc_lengths[i])
  t := table.times[i] + u * (table.times[i + 1] - table.times[i])
  return spline_sample(spline, t)
}

// spline_arc_length returns the total arc length, or 0 without an arc table.
spline_arc_length :: proc(spline: Spline($T)) -> f32 {
  table, has_table := spline.arc_table.?
  if !has_table do return 0
  return slice.last(table.arc_lengths) if len(table.arc_lengths) > 0 else 0
}

// spline_create_closed builds a closed-loop Catmull-Rom spline through `base` (base[N-1] must
// differ from base[0]). Ghost points around the seam keep tangents smooth; the arc table
// covers t in [0, N], so spline_arc_length is exactly one loop.
spline_create_closed :: proc(base: [][3]f32, samples := 200) -> Spline([3]f32) {
  n := len(base)
  result := Spline([3]f32){points = make([][3]f32, n + 3), times = make([]f32, n + 3)}
  closed_points(base, result.points, result.times)
  table := Spline_Arc_Length_Table([3]f32) {
    arc_lengths = make([]f32, samples),
    times       = make([]f32, samples),
  }
  arc_fill(result, table.arc_lengths, table.times, 0, f32(n))
  result.arc_table = table
  return result
}

// The control points (len(base) + 3) and times of a closed loop through `base`.
@(private)
closed_points :: proc(base: [][3]f32, points: [][3]f32, times: []f32) {
  n := len(base)
  points[0] = base[n - 1]
  times[0] = -1
  for i in 0 ..< n {
    points[i + 1] = base[i]
    times[i + 1] = f32(i)
  }
  points[n + 1] = base[0]
  times[n + 1] = f32(n)
  points[n + 2] = base[1]
  times[n + 2] = f32(n + 1)
}
