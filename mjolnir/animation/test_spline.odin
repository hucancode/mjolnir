package animation

import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:log"
import "core:time"
import "base:runtime"

@(test)
test_spline_scalar_interpolation :: proc(t: ^testing.T) {
  spline := spline_create(f32, 4)
  defer spline_destroy(&spline)
  spline.points[0] = 0.0
  spline.points[1] = 10.0
  spline.points[2] = 5.0
  spline.points[3] = 15.0
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  spline.times[3] = 3.0
  testing.expect_value(t, spline_sample(spline, 0.0), 0.0)
  testing.expect_value(t, spline_sample(spline, 1.0), 10.0)
  testing.expect_value(t, spline_sample(spline, 2.0), 5.0)
  testing.expect_value(t, spline_sample(spline, 3.0), 15.0)
  mid := spline_sample(spline, 0.5)
  testing.expect(
    t,
    mid > 0.0 && mid < 10.0,
    "Interpolated value should be between control points",
  )
}

@(test)
test_spline_vector_interpolation :: proc(t: ^testing.T) {
  spline := spline_create([3]f32, 3)
  defer spline_destroy(&spline)
  spline.points[0] = [3]f32{0, 0, 0}
  spline.points[1] = [3]f32{10, 20, 30}
  spline.points[2] = [3]f32{20, 10, 40}
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect_value(
    t,
    spline_sample(spline, 0.0),
    [3]f32{0, 0, 0},
  )
  testing.expect_value(
    t,
    spline_sample(spline, 1.0),
    [3]f32{10, 20, 30},
  )
  testing.expect_value(
    t,
    spline_sample(spline, 2.0),
    [3]f32{20, 10, 40},
  )
  mid := spline_sample(spline, 0.5)
  testing.expect(t, mid.x > 0 && mid.x < 10, "X should interpolate smoothly")
  testing.expect(t, mid.y > 0 && mid.y < 20, "Y should interpolate smoothly")
  testing.expect(t, mid.z > 0 && mid.z < 30, "Z should interpolate smoothly")
}

@(test)
test_spline_quaternion_interpolation :: proc(t: ^testing.T) {
  spline := spline_create(quaternion128, 3)
  defer spline_destroy(&spline)
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
  result_start := spline_sample(spline, 0.0)
  testing.expect(
    t,
    almost_equal_quaternion(result_start, spline.points[0]),
    "Should match first point",
  )
  result_mid := spline_sample(spline, 1.0)
  testing.expect(
    t,
    almost_equal_quaternion(result_mid, spline.points[1]),
    "Should match middle point",
  )
  result_end := spline_sample(spline, 2.0)
  testing.expect(
    t,
    almost_equal_quaternion(result_end, spline.points[2]),
    "Should match last point",
  )
  result_interp := spline_sample(spline, 0.5)
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
  spline := spline_create(f32, 0)
  defer spline_destroy(&spline)
  result := spline_sample(spline, 0.5)
  testing.expect_value(t, result, 0.0)
}

@(test)
test_spline_single_point :: proc(t: ^testing.T) {
  spline := spline_create(f32, 1)
  defer spline_destroy(&spline)
  spline.points[0] = 42.0
  spline.times[0] = 1.0
  testing.expect_value(t, spline_sample(spline, 0.0), 42.0)
  testing.expect_value(t, spline_sample(spline, 1.0), 42.0)
  testing.expect_value(t, spline_sample(spline, 2.0), 42.0)
}

@(test)
test_spline_clamping :: proc(t: ^testing.T) {
  spline := spline_create(f32, 3)
  defer spline_destroy(&spline)
  spline.points[0] = 10.0
  spline.points[1] = 20.0
  spline.points[2] = 30.0
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect_value(t, spline_sample(spline, -1.0), 10.0)
  testing.expect_value(t, spline_sample(spline, 5.0), 30.0)
}

@(test)
test_spline_smooth_curve :: proc(t: ^testing.T) {
  spline := spline_create(f32, 5)
  defer spline_destroy(&spline)
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
  prev := spline_sample(spline, 0.0)
  step_count := 20
  for i in 1 ..< step_count {
    t_val := f32(i) * 4.0 / f32(step_count)
    curr := spline_sample(spline, t_val)
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
  spline := spline_create(f32, 3)
  defer spline_destroy(&spline)
  spline.times[0] = 1.0
  spline.times[1] = 3.0
  spline.times[2] = 5.0
  testing.expect_value(t, spline_duration(spline), 4.0)
  testing.expect_value(t, spline_start_time(spline), 1.0)
  testing.expect_value(t, spline_end_time(spline), 5.0)
}

@(test)
test_spline_nonuniform_times :: proc(t: ^testing.T) {
  spline := spline_create(f32, 4)
  defer spline_destroy(&spline)
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
    spline_validate(spline),
    "Spline should be valid with monotonic times",
  )
  testing.expect_value(t, spline_sample(spline, 0.0), 0.0)
  testing.expect_value(t, spline_sample(spline, 0.5), 10.0)
  testing.expect_value(t, spline_sample(spline, 3.0), 20.0)
  testing.expect_value(t, spline_sample(spline, 4.0), 30.0)
  mid1 := spline_sample(spline, 0.25)
  testing.expect(
    t,
    mid1 > 0.0 && mid1 < 10.0,
    "Should interpolate in first segment",
  )
  mid2 := spline_sample(spline, 1.75)
  testing.expect(
    t,
    mid2 > 10.0 && mid2 < 20.0,
    "Should interpolate in second segment",
  )
}

@(test)
test_spline_validation :: proc(t: ^testing.T) {
  spline := spline_create(f32, 3)
  defer spline_destroy(&spline)
  spline.times[0] = 0.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect(
    t,
    spline_validate(spline),
    "Valid monotonic times should pass",
  )
  spline.times[1] = 2.0
  spline.times[2] = 1.0
  testing.expect(
    t,
    !spline_validate(spline),
    "Non-monotonic times should fail",
  )
  spline.times[0] = 1.0
  spline.times[1] = 1.0
  spline.times[2] = 2.0
  testing.expect(
    t,
    spline_validate(spline),
    "Equal adjacent times are allowed for simplicity",
  )
}

@(test)
bench_spline_sample :: proc(t: ^testing.T) {
	bench_spline_state :: struct {
		spline: Spline([3]f32),
	}
	state: bench_spline_state
	opts := time.Benchmark_Options {
		rounds   = 100_000,
		setup    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_spline_state)opts.user_data
			N :: 32
			s.spline = spline_create([3]f32, N)
			for i in 0 ..< N {
				ti := f32(i) / f32(N - 1)
				s.spline.times[i] = ti
				s.spline.points[i] = {math.cos(ti * 6.0), ti, math.sin(ti * 6.0)}
			}
			return .Okay
		},
		bench    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_spline_state)opts.user_data
			sum: [3]f32
			for k in 0 ..< opts.rounds {
				ti := f32(k) / f32(opts.rounds)
				sum += spline_sample(s.spline, ti)
			}
			opts.count = opts.rounds
			// Touch sum so compiler can't remove the loop
			if sum.x > 1e30 do opts.processed = 0
			return .Okay
		},
		teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_spline_state)opts.user_data
			spline_destroy(&s.spline)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay, "bench failed")
	log.infof("spline_sample N=32 ctrl pts, %d rounds in %v, %.0f rounds/sec",
		opts.rounds, opts.duration, opts.rounds_per_second)
}
