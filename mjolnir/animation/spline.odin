package animation

import "core:math"
import "core:math/linalg"
import "core:slice"

// Catmull-Rom cubic spline for smooth interpolation through control points
// Automatically generates tangents using neighboring points
Spline :: struct($T: typeid) {
  points:    []T,
  times:     []f32,
  arc_table: Maybe(Spline_Arc_Length_Table(T)), // Optional arc-length table for uniform sampling
}

spline_create :: proc($T: typeid, count: int) -> Spline(T) {
  return Spline(T){points = make([]T, count), times = make([]f32, count)}
}

spline_destroy :: proc(spline: ^Spline($T)) {
  delete(spline.points)
  delete(spline.times)
  if table, ok := spline.arc_table.?; ok {
    delete(table.arc_lengths)
    delete(table.times)
  }
}

spline_validate :: proc(spline: Spline($T)) -> bool {
  return slice.is_sorted(spline.times)
}

// Hermite basis functions for cubic interpolation
// h00(t) = 2t^3 - 3t^2 + 1
// h10(t) = t^3 - 2t^2 + t
// h01(t) = -2t^3 + 3t^2
// h11(t) = t^3 - t^2
@(private)
hermite_h00 :: proc(t: f32) -> f32 {
  return 2 * t * t * t - 3 * t * t + 1
}

@(private)
hermite_h10 :: proc(t: f32) -> f32 {
  return t * t * t - 2 * t * t + t
}

@(private)
hermite_h01 :: proc(t: f32) -> f32 {
  return -2 * t * t * t + 3 * t * t
}

@(private)
hermite_h11 :: proc(t: f32) -> f32 {
  return t * t * t - t * t
}

// Catmull-Rom tangent calculation: m_i = (p_{i+1} - p_{i-1}) / 2
@(private)
catmull_rom_tangent :: proc(p_prev: $T, p_next: T) -> T {
  return (p_next - p_prev) * 0.5
}

spline_sample :: proc(spline: Spline($T), t: f32) -> T {
  // spline.times should be monotonically non-decreasing (use spline_validate to check)
  n := len(spline.points)
  if n == 0 {
    return T{}
  }
  if n == 1 {
    return slice.first(spline.points)
  }
  // Clamp to valid range
  if t <= slice.first(spline.times) {
    return slice.first(spline.points)
  }
  if t >= slice.last(spline.times) {
    return slice.last(spline.points)
  }

  // Binary search for segment containing t
  // Returns the index where t would be inserted (first element > t)
  cmp :: proc(item: f32, t: f32) -> slice.Ordering {
    return slice.Ordering.Less if item < t else slice.Ordering.Greater
  }
  idx, _ := slice.binary_search_by(spline.times, t, cmp)
  // binary_search returns insertion point, we need the segment before it
  i := idx - 1

  // Get segment endpoints
  p0 := spline.points[i]
  p1 := spline.points[i + 1]
  t0 := spline.times[i]
  t1 := spline.times[i + 1]

  // Normalized parameter [0, 1] within segment
  u := (t - t0) / (t1 - t0)

  // Calculate tangents using Catmull-Rom method
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

    // Scale tangents by time delta
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

    // Hermite interpolation
    h00 := hermite_h00(u)
    h10 := hermite_h10(u)
    h01 := hermite_h01(u)
    h11 := hermite_h11(u)

    result_x := h00 * p0.x + h10 * m0_scaled.x + h01 * p1.x + h11 * m1_scaled.x
    result_y := h00 * p0.y + h10 * m0_scaled.y + h01 * p1.y + h11 * m1_scaled.y
    result_z := h00 * p0.z + h10 * m0_scaled.z + h01 * p1.z + h11 * m1_scaled.z
    result_w := h00 * p0.w + h10 * m0_scaled.w + h01 * p1.w + h11 * m1_scaled.w

    return linalg.normalize(
      quaternion(x = result_x, y = result_y, z = result_z, w = result_w),
    )
  } else {
    // For vectors and scalars
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

    // Scale tangents by time delta
    dt := t1 - t0
    m0 *= dt
    m1 *= dt

    // Hermite interpolation
    h00 := hermite_h00(u)
    h10 := hermite_h10(u)
    h01 := hermite_h01(u)
    h11 := hermite_h11(u)

    return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
  }
}

spline_duration :: proc(spline: Spline($T)) -> f32 {
  if len(spline.times) == 0 {
    return 0
  }
  return slice.last(spline.times) - slice.first(spline.times)
}

spline_start_time :: proc(spline: Spline($T)) -> f32 {
  if len(spline.times) == 0 {
    return 0
  }
  return slice.first(spline.times)
}

spline_end_time :: proc(spline: Spline($T)) -> f32 {
  if len(spline.times) == 0 {
    return 0
  }
  return slice.last(spline.times)
}

// Arc-length lookup table for uniform spatial sampling
Spline_Arc_Length_Table :: struct($T: typeid) {
  arc_lengths: []f32, // Cumulative arc-lengths at sample points
  times:       []f32, // Corresponding time values
}

spline_build_arc_table :: proc(spline: ^Spline($T), samples := 200) {
  // samples: Number of samples for approximation (more = accurate but slower)
  table := Spline_Arc_Length_Table(T) {
    arc_lengths = make([]f32, samples),
    times       = make([]f32, samples),
  }
  t_start := spline_start_time(spline^)
  t_end := spline_end_time(spline^)
  t_range := t_end - t_start
  prev_pos := spline_sample(spline^, t_start)
  total_length := f32(0)
  for i in 0 ..< samples {
    t := t_start + f32(i) * t_range / f32(samples - 1)
    pos := spline_sample(spline^, t)
    if i > 0 do total_length += linalg.distance(pos, prev_pos)
    table.arc_lengths[i] = total_length
    table.times[i] = t
    prev_pos = pos
  }
  spline.arc_table = table
}

spline_sample_uniform :: proc(spline: Spline($T), s: f32) -> T {
  // s: Arc-length parameter [0, total_length]
  table, ok := spline.arc_table.?
  if !ok do return spline_sample(spline, s)
  n := len(table.arc_lengths)
  if n == 0 do return T{}
  if s <= 0 do return spline_sample(spline, table.times[0])
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

spline_arc_length :: proc(spline: Spline($T)) -> f32 {
  table, has_table := spline.arc_table.?
  if !has_table do return 0
  return slice.last(table.arc_lengths) if len(table.arc_lengths) > 0 else 0
}
