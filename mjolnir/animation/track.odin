package animation

import "core:math/linalg"

// Interpolation selects how a Track blends between keys.
Interpolation :: enum u8 {
  LINEAR,
  STEP,
  CUBIC,
}

// Track is a keyframed curve of any value over flat arrays. A track does not own its
// memory; it is a view (into a Clip, or into caller arrays).
// CUBIC stores three values per key: in-tangent, value, out-tangent.
Track :: struct($T: typeid) {
  times:         []f32,
  values:        []T,
  interpolation: Interpolation,
}

@(private)
track_duration :: proc(track: Track($T)) -> f32 {
  return track.times[len(track.times) - 1] if len(track.times) > 0 else 0
}

@(private)
track_value :: #force_inline proc(track: Track($T), key: int) -> T {
  return track.values[key * 3 + 1] if track.interpolation == .CUBIC else track.values[key]
}

// Value of `track` at time `t`, clamped to the first and last key.
// Returns `fallback` for an empty track.
@(private)
track_sample :: proc(track: Track($T), t: f32, fallback: T) -> T {
  n := len(track.times)
  if n == 0 do return fallback
  if t <= track.times[0] do return track_value(track, 0)
  if t >= track.times[n - 1] do return track_value(track, n - 1)
  // first key with time > t
  lo, hi := 1, n - 1
  for lo < hi {
    mid := (lo + hi) / 2
    if track.times[mid] > t do hi = mid
    else do lo = mid + 1
  }
  a, b := lo - 1, lo
  dt := track.times[b] - track.times[a]
  u := (t - track.times[a]) / dt
  switch track.interpolation {
  case .STEP:
    return track.values[a]
  case .LINEAR:
    when T == quaternion128 {
      return linalg.quaternion_slerp(track.values[a], track.values[b], u)
    } else {
      return linalg.lerp(track.values[a], track.values[b], u)
    }
  case .CUBIC:
    u2 := u * u
    u3 := u2 * u
    h00 := 2 * u3 - 3 * u2 + 1
    h10 := u3 - 2 * u2 + u
    h01 := -2 * u3 + 3 * u2
    h11 := u3 - u2
    p0 := track.values[a * 3 + 1]
    m0 := track.values[a * 3 + 2]
    p1 := track.values[b * 3 + 1]
    m1 := track.values[b * 3]
    when T == quaternion128 {
      v0, t0, v1, t1 := transmute([4]f32)p0, transmute([4]f32)m0, transmute([4]f32)p1, transmute([4]f32)m1
      r := h00 * v0 + h10 * dt * t0 + h01 * v1 + h11 * dt * t1
      return linalg.normalize(transmute(quaternion128)r)
    } else {
      return h00 * p0 + h10 * dt * m0 + h01 * p1 + h11 * dt * m1
    }
  }
  return fallback
}
