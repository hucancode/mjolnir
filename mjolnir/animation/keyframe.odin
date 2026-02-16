package animation

import "core:math"
import "core:math/linalg"
import "core:slice"

InterpolationMode :: enum {
  LINEAR,
  STEP,
  CUBICSPLINE,
}

LinearKeyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

StepKeyframe :: struct($T: typeid) {
  time:  f32,
  value: T,
}

CubicSplineKeyframe :: struct($T: typeid) {
  time:        f32,
  in_tangent:  T,
  value:       T,
  out_tangent: T,
}

Keyframe :: union($T: typeid) {
  LinearKeyframe(T),
  StepKeyframe(T),
  CubicSplineKeyframe(T),
}

// Helper to get time from any keyframe variant
keyframe_time :: proc(kf: Keyframe($T)) -> f32 {
  switch v in kf {
  case LinearKeyframe(T):
    return v.time
  case StepKeyframe(T):
    return v.time
  case CubicSplineKeyframe(T):
    return v.time
  }
  return 0
}

// Helper to get value from any keyframe variant
keyframe_value :: proc(kf: Keyframe($T)) -> T {
  switch v in kf {
  case LinearKeyframe(T):
    return v.value
  case StepKeyframe(T):
    return v.value
  case CubicSplineKeyframe(T):
    return v.value
  }
  return T{}
}

// 9 interpolation helpers for all combinations
sample_linear_linear :: proc(
  a: LinearKeyframe($T),
  b: LinearKeyframe(T),
  t: f32,
) -> T {
  alpha := (t - a.time) / (b.time - a.time)
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    return linalg.quaternion_slerp(a.value, b.value, alpha)
  } else {
    return linalg.lerp(a.value, b.value, alpha)
  }
}

sample_linear_step :: proc(
  a: LinearKeyframe($T),
  b: StepKeyframe(T),
  t: f32,
) -> T {
  return a.value
}

sample_linear_cubic :: proc(
  a: LinearKeyframe($T),
  b: CubicSplineKeyframe(T),
  t: f32,
) -> T {
  dt := b.time - a.time
  u := (t - a.time) / dt
  u2 := u * u
  u3 := u2 * u
  h00 := 2 * u3 - 3 * u2 + 1
  h01 := -2 * u3 + 3 * u2
  h11 := u3 - u2
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    q0 := a.value
    q1 := b.value
    m1_scaled := quaternion(
      x = b.in_tangent.x * dt,
      y = b.in_tangent.y * dt,
      z = b.in_tangent.z * dt,
      w = b.in_tangent.w * dt,
    )
    result_x := h00 * q0.x + h01 * q1.x + h11 * m1_scaled.x
    result_y := h00 * q0.y + h01 * q1.y + h11 * m1_scaled.y
    result_z := h00 * q0.z + h01 * q1.z + h11 * m1_scaled.z
    result_w := h00 * q0.w + h01 * q1.w + h11 * m1_scaled.w
    return linalg.normalize(
      quaternion(x = result_x, y = result_y, z = result_z, w = result_w),
    )
  } else {
    return h00 * a.value + h01 * b.value + h11 * (b.in_tangent * dt)
  }
}

sample_step_linear :: proc(
  a: StepKeyframe($T),
  b: LinearKeyframe(T),
  t: f32,
) -> T {
  // Step holds value until we reach the next keyframe's exact time
  if t >= b.time {
    return b.value
  }
  return a.value
}

sample_step_step :: proc(
  a: StepKeyframe($T),
  b: StepKeyframe(T),
  t: f32,
) -> T {
  // Step holds value until we reach the next keyframe's exact time
  if t >= b.time {
    return b.value
  }
  return a.value
}

sample_step_cubic :: proc(
  a: StepKeyframe($T),
  b: CubicSplineKeyframe(T),
  t: f32,
) -> T {
  // Step holds value until we reach the next keyframe's exact time
  if t >= b.time {
    return b.value
  }
  return a.value
}

sample_cubic_linear :: proc(
  a: CubicSplineKeyframe($T),
  b: LinearKeyframe(T),
  t: f32,
) -> T {
  dt := b.time - a.time
  u := (t - a.time) / dt
  u2 := u * u
  u3 := u2 * u
  h00 := 2 * u3 - 3 * u2 + 1
  h10 := u3 - 2 * u2 + u
  h01 := -2 * u3 + 3 * u2
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    q0 := a.value
    m0_scaled := quaternion(
      x = a.out_tangent.x * dt,
      y = a.out_tangent.y * dt,
      z = a.out_tangent.z * dt,
      w = a.out_tangent.w * dt,
    )
    q1 := b.value
    result_x := h00 * q0.x + h10 * m0_scaled.x + h01 * q1.x
    result_y := h00 * q0.y + h10 * m0_scaled.y + h01 * q1.y
    result_z := h00 * q0.z + h10 * m0_scaled.z + h01 * q1.z
    result_w := h00 * q0.w + h10 * m0_scaled.w + h01 * q1.w
    return linalg.normalize(
      quaternion(x = result_x, y = result_y, z = result_z, w = result_w),
    )
  } else {
    return h00 * a.value + h10 * (a.out_tangent * dt) + h01 * b.value
  }
}

sample_cubic_step :: proc(
  a: CubicSplineKeyframe($T),
  b: StepKeyframe(T),
  t: f32,
) -> T {
  return a.value
}

sample_cubic_cubic :: proc(
  a: CubicSplineKeyframe($T),
  b: CubicSplineKeyframe(T),
  t: f32,
) -> T {
  dt := b.time - a.time
  u := (t - a.time) / dt
  u2 := u * u
  u3 := u2 * u
  h00 := 2 * u3 - 3 * u2 + 1
  h10 := u3 - 2 * u2 + u
  h01 := -2 * u3 + 3 * u2
  h11 := u3 - u2
  when T == quaternion64 || T == quaternion128 || T == quaternion256 {
    q0 := a.value
    m0_scaled := quaternion(
      x = a.out_tangent.x * dt,
      y = a.out_tangent.y * dt,
      z = a.out_tangent.z * dt,
      w = a.out_tangent.w * dt,
    )
    q1 := b.value
    m1_scaled := quaternion(
      x = b.in_tangent.x * dt,
      y = b.in_tangent.y * dt,
      z = b.in_tangent.z * dt,
      w = b.in_tangent.w * dt,
    )
    result_x := h00 * q0.x + h10 * m0_scaled.x + h01 * q1.x + h11 * m1_scaled.x
    result_y := h00 * q0.y + h10 * m0_scaled.y + h01 * q1.y + h11 * m1_scaled.y
    result_z := h00 * q0.z + h10 * m0_scaled.z + h01 * q1.z + h11 * m1_scaled.z
    result_w := h00 * q0.w + h10 * m0_scaled.w + h01 * q1.w + h11 * m1_scaled.w
    return linalg.normalize(
      quaternion(x = result_x, y = result_y, z = result_z, w = result_w),
    )
  } else {
    return(
      h00 * a.value +
      h10 * (a.out_tangent * dt) +
      h01 * b.value +
      h11 * (b.in_tangent * dt) \
    )
  }
}

keyframe_sample :: proc(frames: []Keyframe($T), t: f32, fallback: T) -> T {
  if len(frames) == 0 {
    return fallback
  }

  first_time := keyframe_time(slice.first(frames))
  last_time := keyframe_time(slice.last(frames))

  if t <= first_time {
    return keyframe_value(slice.first(frames))
  }

  if t >= last_time {
    return keyframe_value(slice.last(frames))
  }

  cmp :: proc(item: Keyframe(T), t: f32) -> slice.Ordering {
    item_time := keyframe_time(item)
    return slice.Ordering.Less if item_time < t else slice.Ordering.Greater
  }
  i, _ := slice.binary_search_by(frames, t, cmp)

  a := frames[i - 1]
  b := frames[i]
  switch a_variant in a {
  case LinearKeyframe(T):
    switch b_variant in b {
    case LinearKeyframe(T):
      return sample_linear_linear(a_variant, b_variant, t)
    case StepKeyframe(T):
      return sample_linear_step(a_variant, b_variant, t)
    case CubicSplineKeyframe(T):
      return sample_linear_cubic(a_variant, b_variant, t)
    }
  case StepKeyframe(T):
    switch b_variant in b {
    case LinearKeyframe(T):
      return sample_step_linear(a_variant, b_variant, t)
    case StepKeyframe(T):
      return sample_step_step(a_variant, b_variant, t)
    case CubicSplineKeyframe(T):
      return sample_step_cubic(a_variant, b_variant, t)
    }
  case CubicSplineKeyframe(T):
    switch b_variant in b {
    case LinearKeyframe(T):
      return sample_cubic_linear(a_variant, b_variant, t)
    case StepKeyframe(T):
      return sample_cubic_step(a_variant, b_variant, t)
    case CubicSplineKeyframe(T):
      return sample_cubic_cubic(a_variant, b_variant, t)
    }
  }

  return fallback
}
