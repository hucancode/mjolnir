package tests

import "../mjolnir/animation"
import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_spline_scalar_interpolation :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 4)
  defer animation.spline_destroy(&spline)
  spline.points[0] = 0.0
  spline.points[1] = 10.0
  spline.points[2] = 5.0
  spline.points[3] = 15.0
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  spline.times[3] = 3.0
  testing.expect_value(t, animation.spline_sample(spline, 0.0), 0.0)
  testing.expect_value(t, animation.spline_sample(spline, 1.0), 10.0)
  testing.expect_value(t, animation.spline_sample(spline, 2.0), 5.0)
  testing.expect_value(t, animation.spline_sample(spline, 3.0), 15.0)
  mid := animation.spline_sample(spline, 0.5)
  testing.expect(
    t,
    mid > 0.0 && mid < 10.0,
    "Interpolated value should be between control points",
  )
}

@(test)
test_spline_vector_interpolation :: proc(t: ^testing.T) {
  spline := animation.spline_create([3]f32, 3)
  defer animation.spline_destroy(&spline)
  spline.points[0] = [3]f32{0, 0, 0}
  spline.points[1] = [3]f32{10, 20, 30}
  spline.points[2] = [3]f32{20, 10, 40}
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect_value(
    t,
    animation.spline_sample(spline, 0.0),
    [3]f32{0, 0, 0},
  )
  testing.expect_value(
    t,
    animation.spline_sample(spline, 1.0),
    [3]f32{10, 20, 30},
  )
  testing.expect_value(
    t,
    animation.spline_sample(spline, 2.0),
    [3]f32{20, 10, 40},
  )
  mid := animation.spline_sample(spline, 0.5)
  testing.expect(t, mid.x > 0 && mid.x < 10, "X should interpolate smoothly")
  testing.expect(t, mid.y > 0 && mid.y < 20, "Y should interpolate smoothly")
  testing.expect(t, mid.z > 0 && mid.z < 30, "Z should interpolate smoothly")
}

@(test)
test_spline_quaternion_interpolation :: proc(t: ^testing.T) {
  spline := animation.spline_create(quaternion128, 3)
  defer animation.spline_destroy(&spline)
  spline.points[0] = linalg.quaternion_angle_axis(0, linalg.VECTOR3F32_Z_AXIS)
  spline.points[1] = linalg.quaternion_angle_axis(
    math.PI / 2,
    linalg.VECTOR3F32_Z_AXIS,
  )
  spline.points[2] = linalg.quaternion_angle_axis(
    math.PI,
    linalg.VECTOR3F32_Z_AXIS,
  )
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  result_start := animation.spline_sample(spline, 0.0)
  testing.expect(
    t,
    almost_equal_quaternion(result_start, spline.points[0]),
    "Should match first point",
  )
  result_mid := animation.spline_sample(spline, 1.0)
  testing.expect(
    t,
    almost_equal_quaternion(result_mid, spline.points[1]),
    "Should match middle point",
  )
  result_end := animation.spline_sample(spline, 2.0)
  testing.expect(
    t,
    almost_equal_quaternion(result_end, spline.points[2]),
    "Should match last point",
  )
  result_interp := animation.spline_sample(spline, 0.5)
  length_sq :=
    result_interp.w * result_interp.w +
    result_interp.x * result_interp.x +
    result_interp.y * result_interp.y +
    result_interp.z * result_interp.z
  testing.expect(
    t,
    abs(length_sq - 1.0) < 0.01,
    "Quaternion should remain normalized",
  )
}

@(test)
test_spline_empty :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 0)
  defer animation.spline_destroy(&spline)
  result := animation.spline_sample(spline, 0.5)
  testing.expect_value(t, result, 0.0)
}

@(test)
test_spline_single_point :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 1)
  defer animation.spline_destroy(&spline)
  spline.points[0] = 42.0
  spline.times[0] = 1.0
  testing.expect_value(t, animation.spline_sample(spline, 0.0), 42.0)
  testing.expect_value(t, animation.spline_sample(spline, 1.0), 42.0)
  testing.expect_value(t, animation.spline_sample(spline, 2.0), 42.0)
}

@(test)
test_spline_clamping :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 3)
  defer animation.spline_destroy(&spline)
  spline.points[0] = 10.0
  spline.points[1] = 20.0
  spline.points[2] = 30.0
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect_value(t, animation.spline_sample(spline, -1.0), 10.0)
  testing.expect_value(t, animation.spline_sample(spline, 5.0), 30.0)
}

@(test)
test_spline_smooth_curve :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 5)
  defer animation.spline_destroy(&spline)
  spline.points[0] = 0.0
  spline.points[1] = 10.0
  spline.points[2] = 5.0
  spline.points[3] = 15.0
  spline.points[4] = 10.0
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  spline.times[3] = 3.0
  spline.times[4] = 4.0
  prev := animation.spline_sample(spline, 0.0)
  step_count := 20
  for i in 1 ..< step_count {
    t_val := f32(i) * 4.0 / f32(step_count)
    curr := animation.spline_sample(spline, t_val)
    delta := abs(curr - prev)
    testing.expect(
      t,
      delta < 5.0,
      "Spline should produce smooth transitions without large jumps",
    )
    prev = curr
  }
}

@(test)
test_spline_duration :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 3)
  defer animation.spline_destroy(&spline)
  spline.times[0] = 1.0
  spline.times[1] = 3.0
  spline.times[2] = 5.0
  testing.expect_value(t, animation.spline_duration(spline), 4.0)
  testing.expect_value(t, animation.spline_start_time(spline), 1.0)
  testing.expect_value(t, animation.spline_end_time(spline), 5.0)
}

@(test)
test_spline_nonuniform_times :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 4)
  defer animation.spline_destroy(&spline)
  spline.points[0] = 0.0
  spline.points[1] = 10.0
  spline.points[2] = 20.0
  spline.points[3] = 30.0
  spline.times[0] = 0.0
  spline.times[1] = 0.5
  spline.times[2] = 3.0
  spline.times[3] = 4.0
  testing.expect(
    t,
    animation.spline_validate(spline),
    "Spline should be valid with monotonic times",
  )
  testing.expect_value(t, animation.spline_sample(spline, 0.0), 0.0)
  testing.expect_value(t, animation.spline_sample(spline, 0.5), 10.0)
  testing.expect_value(t, animation.spline_sample(spline, 3.0), 20.0)
  testing.expect_value(t, animation.spline_sample(spline, 4.0), 30.0)
  mid1 := animation.spline_sample(spline, 0.25)
  testing.expect(
    t,
    mid1 > 0.0 && mid1 < 10.0,
    "Should interpolate in first segment",
  )
  mid2 := animation.spline_sample(spline, 1.75)
  testing.expect(
    t,
    mid2 > 10.0 && mid2 < 20.0,
    "Should interpolate in second segment",
  )
}

@(test)
test_spline_validation :: proc(t: ^testing.T) {
  spline := animation.spline_create(f32, 3)
  defer animation.spline_destroy(&spline)
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect(
    t,
    animation.spline_validate(spline),
    "Valid monotonic times should pass",
  )
  spline.times[1] = 2.0
  spline.times[2] = 1.0
  testing.expect(
    t,
    !animation.spline_validate(spline),
    "Non-monotonic times should fail",
  )
  spline.times[0] = 1.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect(
    t,
    animation.spline_validate(spline),
    "Equal adjacent times are allowed for simplicity",
  )
}
