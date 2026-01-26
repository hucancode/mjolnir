package animation

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_sample_valid :: proc(t: ^testing.T) {
  frames := []Keyframe(f32) {
    LinearKeyframe(f32){time = 0.0, value = 0.0},
    LinearKeyframe(f32){time = 1.0, value = 10.0},
  }
  result := keyframe_sample(frames, 0.5, 0.0)
  testing.expect_value(t, result, 5.0)
}

@(test)
test_sample_step_interpolation :: proc(t: ^testing.T) {
  frames := []Keyframe(f32) {
    StepKeyframe(f32){time = 0.0, value = 0.0},
    StepKeyframe(f32){time = 1.0, value = 10.0},
    StepKeyframe(f32){time = 2.0, value = 20.0},
  }
  testing.expect_value(t, keyframe_sample(frames, 0.0, 0.0), 0.0)
  testing.expect_value(t, keyframe_sample(frames, 0.5, 0.0), 0.0)
  testing.expect_value(t, keyframe_sample(frames, 0.99, 0.0), 0.0)
  testing.expect_value(t, keyframe_sample(frames, 1.0, 0.0), 10.0)
  testing.expect_value(t, keyframe_sample(frames, 1.5, 0.0), 10.0)
  testing.expect_value(t, keyframe_sample(frames, 1.99, 0.0), 10.0)
  testing.expect_value(t, keyframe_sample(frames, 2.0, 0.0), 20.0)
  testing.expect_value(t, keyframe_sample(frames, 3.0, 0.0), 20.0)
}

@(test)
test_sample_step_interpolation_single_frame :: proc(t: ^testing.T) {
  frames := []Keyframe(f32) {
    StepKeyframe(f32){time = 1.0, value = 42.0},
  }
  testing.expect_value(t, keyframe_sample(frames, 0.0, 0.0), 42.0)
  testing.expect_value(t, keyframe_sample(frames, 1.0, 0.0), 42.0)
  testing.expect_value(t, keyframe_sample(frames, 2.0, 0.0), 42.0)
}

@(test)
test_sample_cubic_spline_interpolation :: proc(t: ^testing.T) {
  frames := []Keyframe(f32) {
    CubicSplineKeyframe(f32) {
      time = 0.0,
      in_tangent = 0.0,
      value = 0.0,
      out_tangent = 5.0,
    },
    CubicSplineKeyframe(f32) {
      time = 1.0,
      in_tangent = 5.0,
      value = 10.0,
      out_tangent = 0.0,
    },
  }
  testing.expect_value(t, keyframe_sample(frames, 0.0, 0.0), 0.0)
  testing.expect_value(t, keyframe_sample(frames, 1.0, 0.0), 10.0)
  mid := keyframe_sample(frames, 0.5, 0.0)
  testing.expect(
    t,
    mid > 0.0 && mid < 10.0,
    "Cubic interpolation should produce smooth curve",
  )
}

@(test)
test_sample_cubic_spline_vector_interpolation :: proc(t: ^testing.T) {
  frames := []Keyframe([3]f32) {
    CubicSplineKeyframe([3]f32) {
      time = 0.0,
      in_tangent = {0, 0, 0},
      value = {0, 0, 0},
      out_tangent = {1, 2, 3},
    },
    CubicSplineKeyframe([3]f32) {
      time = 1.0,
      in_tangent = {1, 2, 3},
      value = {10, 20, 30},
      out_tangent = {0, 0, 0},
    },
  }
  result_start := keyframe_sample(frames, 0.0, [3]f32{0, 0, 0})
  testing.expect_value(t, result_start, [3]f32{0, 0, 0})
  result_end := keyframe_sample(frames, 1.0, [3]f32{0, 0, 0})
  testing.expect_value(t, result_end, [3]f32{10, 20, 30})
  result_mid := keyframe_sample(frames, 0.5, [3]f32{0, 0, 0})
  testing.expect(
    t,
    result_mid.x > 0 && result_mid.x < 10,
    "X component should be interpolated",
  )
  testing.expect(
    t,
    result_mid.y > 0 && result_mid.y < 20,
    "Y component should be interpolated",
  )
  testing.expect(
    t,
    result_mid.z > 0 && result_mid.z < 30,
    "Z component should be interpolated",
  )
}

@(test)
test_sample_cubic_spline_quaternion_interpolation :: proc(t: ^testing.T) {
  q1 := linalg.quaternion_angle_axis(0, linalg.VECTOR3F32_Z_AXIS)
  q2 := linalg.quaternion_angle_axis(math.PI / 2, linalg.VECTOR3F32_Z_AXIS)
  tangent: quaternion128 = quaternion(w = 0, x = 0, y = 0, z = 0.5)
  frames := []Keyframe(quaternion128) {
    CubicSplineKeyframe(quaternion128) {
      time = 0.0,
      in_tangent = tangent,
      value = q1,
      out_tangent = tangent,
    },
    CubicSplineKeyframe(quaternion128) {
      time = 1.0,
      in_tangent = tangent,
      value = q2,
      out_tangent = tangent,
    },
  }
  result_start := keyframe_sample(
    frames,
    0.0,
    linalg.QUATERNIONF32_IDENTITY,
  )
  testing.expect(
    t,
    almost_equal_quaternion(result_start, q1),
    "Should match first keyframe",
  )
  result_end := keyframe_sample(
    frames,
    1.0,
    linalg.QUATERNIONF32_IDENTITY,
  )
  testing.expect(
    t,
    almost_equal_quaternion(result_end, q2),
    "Should match second keyframe",
  )
  result_mid := keyframe_sample(
    frames,
    0.5,
    linalg.QUATERNIONF32_IDENTITY,
  )
  length_sq :=
    result_mid.w * result_mid.w +
    result_mid.x * result_mid.x +
    result_mid.y * result_mid.y +
    result_mid.z * result_mid.z
  testing.expect(t, length_sq > 0.8, "Quaternion should be normalized")
}

@(test)
test_sample_no_data :: proc(t: ^testing.T) {
  frames: []Keyframe(f32)
  result := keyframe_sample(frames, 0.5, 0.0)
  testing.expect_value(t, result, 0.0)
  result = keyframe_sample(frames, 0.5, 999.0)
  testing.expect_value(t, result, 999.0)
}

@(test)
test_sample_one_data_point :: proc(t: ^testing.T) {
  frames := []Keyframe(f32) {
    LinearKeyframe(f32){time = 0.0, value = 42.0},
  }
  result := keyframe_sample(frames, 0.0, 0.0)
  testing.expect_value(t, result, 42.0)
  result = keyframe_sample(frames, 1.0, 0.0)
  testing.expect_value(t, result, 42.0)
  result = keyframe_sample(frames, -1.0, 0.0)
  testing.expect_value(t, result, 42.0)
}

@(test)
test_sample_edge :: proc(t: ^testing.T) {
  frames := []Keyframe(f32) {
    LinearKeyframe(f32){time = 0.0, value = 1.0},
    LinearKeyframe(f32){time = 1.0, value = 3.0},
  }
  result := keyframe_sample(frames, 0.0, 0.0)
  testing.expect_value(t, result, 1.0)
  result = keyframe_sample(frames, 1.0, 0.0)
  testing.expect_value(t, result, 3.0)
}

@(test)
test_sample_out_of_range :: proc(t: ^testing.T) {
  frames := []Keyframe(f32) {
    LinearKeyframe(f32){time = 0.0, value = 2.0},
    LinearKeyframe(f32){time = 1.0, value = 4.0},
  }
  // Before first keyframe
  result1 := keyframe_sample(frames, -1.0, 0.0)
  testing.expect_value(t, result1, 2.0)
  // After last keyframe
  result2 := keyframe_sample(frames, 2.0, 0.0)
  testing.expect_value(t, result2, 4.0)
}

@(test)
test_position_sampling :: proc(t: ^testing.T) {
  frames := []Keyframe([3]f32) {
    LinearKeyframe([3]f32){time = 0.0, value = {0, 0, 0}},
    LinearKeyframe([3]f32){time = 1.0, value = {1, 2, 3}},
    LinearKeyframe([3]f32){time = 2.0, value = {2, 4, 6}},
  }
  // value range is small, don't need almost_equal, we can use exact comparison
  // exact matches
  testing.expect_value(
    t,
    keyframe_sample(frames, 0.0, [3]f32{0, 0, 0}),
    [3]f32{0, 0, 0},
  )
  testing.expect_value(
    t,
    keyframe_sample(frames, 1.0, [3]f32{0, 0, 0}),
    [3]f32{1, 2, 3},
  )
  testing.expect_value(
    t,
    keyframe_sample(frames, 2.0, [3]f32{0, 0, 0}),
    [3]f32{2, 4, 6},
  )
  // interpolation
  testing.expect_value(
    t,
    keyframe_sample(frames, 0.5, [3]f32{0, 0, 0}),
    [3]f32{0.5, 1, 1.5},
  )
  testing.expect_value(
    t,
    keyframe_sample(frames, 1.5, [3]f32{0, 0, 0}),
    [3]f32{1.5, 3, 4.5},
  )
  // out of range
  testing.expect_value(
    t,
    keyframe_sample(frames, -1.0, [3]f32{0, 0, 0}),
    [3]f32{0, 0, 0},
  )
  testing.expect_value(
    t,
    keyframe_sample(frames, 3.0, [3]f32{0, 0, 0}),
    [3]f32{2, 4, 6},
  )
}

almost_equal_quaternion :: proc(a, b: quaternion128) -> bool {
  return(
    a.x - b.x <= math.F32_EPSILON &&
    a.y - b.y <= math.F32_EPSILON &&
    a.z - b.z <= math.F32_EPSILON &&
    a.w - b.w <= math.F32_EPSILON \
  )
}

@(test)
test_quaternion_sampling :: proc(t: ^testing.T) {
  q1 := linalg.quaternion_angle_axis(0, linalg.VECTOR3F32_Z_AXIS) // Identity
  q2 := linalg.quaternion_angle_axis(math.PI, linalg.VECTOR3F32_Z_AXIS)
  q3 := linalg.quaternion_angle_axis(math.PI, linalg.VECTOR3F32_Y_AXIS)
  q4 := linalg.quaternion_angle_axis(math.PI, linalg.VECTOR3F32_X_AXIS)
  frames := []Keyframe(quaternion128) {
    LinearKeyframe(quaternion128){time = 0.0, value = q1},
    LinearKeyframe(quaternion128){time = 1.0, value = q2},
    LinearKeyframe(quaternion128){time = 2.0, value = q3},
    LinearKeyframe(quaternion128){time = 3.0, value = q4},
  }
  // exact matches
  testing.expect(
    t,
    almost_equal_quaternion(
      keyframe_sample(frames, 0.0, linalg.QUATERNIONF32_IDENTITY),
      q1,
    ),
  )
  testing.expect(
    t,
    almost_equal_quaternion(
      keyframe_sample(frames, 1.0, linalg.QUATERNIONF32_IDENTITY),
      q2,
    ),
  )
  testing.expect(
    t,
    almost_equal_quaternion(
      keyframe_sample(frames, 2.0, linalg.QUATERNIONF32_IDENTITY),
      q3,
    ),
  )
  testing.expect(
    t,
    almost_equal_quaternion(
      keyframe_sample(frames, 3.0, linalg.QUATERNIONF32_IDENTITY),
      q4,
    ),
  )
  // interpolation
  half_rot := keyframe_sample(
    frames,
    0.5,
    linalg.QUATERNIONF32_IDENTITY,
  )
  expected_half := linalg.quaternion_angle_axis(
    math.PI / 2,
    linalg.VECTOR3F32_Z_AXIS,
  )
  testing.expect(t, almost_equal_quaternion(half_rot, expected_half))
}

@(test)
test_channel_init_linear :: proc(t: ^testing.T) {
  clip := clip_create(channel_count = 1, duration = 3.0)
  defer clip_destroy(&clip)
  channel_init(
    &clip.channels[0],
    position_count = 4,
    rotation_count = 3,
    scale_count = 2,
    duration = clip.duration,
  )
  testing.expect_value(t, len(clip.channels[0].positions), 4)
  testing.expect_value(t, len(clip.channels[0].rotations), 3)
  testing.expect_value(t, len(clip.channels[0].scales), 2)
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].positions[0]),
    0.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].positions[1]),
    1.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].positions[2]),
    2.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].positions[3]),
    3.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].rotations[0]),
    0.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].rotations[1]),
    1.5,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].rotations[2]),
    3.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].scales[0]),
    0.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].scales[1]),
    3.0,
  )
  testing.expect_value(
    t,
    keyframe_value(clip.channels[0].positions[0]),
    [3]f32{0, 0, 0},
  )
  testing.expect(
    t,
    almost_equal_quaternion(
      keyframe_value(clip.channels[0].rotations[0]),
      linalg.QUATERNIONF32_IDENTITY,
    ),
  )
  testing.expect_value(
    t,
    keyframe_value(clip.channels[0].scales[0]),
    [3]f32{1, 1, 1},
  )
}

@(test)
test_channel_init_cubic :: proc(t: ^testing.T) {
  clip := clip_create(channel_count = 1, duration = 2.0)
  defer clip_destroy(&clip)
  channel_init(
    &clip.channels[0],
    position_count = 3,
    position_interpolation = .CUBICSPLINE,
    duration = clip.duration,
  )
  testing.expect_value(t, len(clip.channels[0].positions), 3)
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].positions[0]),
    0.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].positions[1]),
    1.0,
  )
  testing.expect_value(
    t,
    keyframe_time(clip.channels[0].positions[2]),
    2.0,
  )
  // Check that the keyframes are CubicSplineKeyframe type
  switch kf in clip.channels[0].positions[0] {
  case CubicSplineKeyframe([3]f32):
    testing.expect_value(t, kf.value, [3]f32{0, 0, 0})
    testing.expect_value(t, kf.in_tangent, [3]f32{0, 0, 0})
    testing.expect_value(t, kf.out_tangent, [3]f32{0, 0, 0})
  case LinearKeyframe([3]f32), StepKeyframe([3]f32):
    testing.fail(t)
  }
}

@(test)
test_channel_init_modify_and_sample :: proc(t: ^testing.T) {
  clip := clip_create(channel_count = 1, duration = 2.0)
  defer clip_destroy(&clip)
  channel_init(
    &clip.channels[0],
    position_count = 3,
    rotation_count = 2,
    duration = clip.duration,
  )
  // Modify keyframe values using switch to access the union variants
  switch &kf in clip.channels[0].positions[0] {
  case LinearKeyframe([3]f32):
    kf.value = [3]f32{0, 0, 0}
  case StepKeyframe([3]f32), CubicSplineKeyframe([3]f32):
  // Not expected for this test
  }
  switch &kf in clip.channels[0].positions[1] {
  case LinearKeyframe([3]f32):
    kf.value = [3]f32{1, 2, 3}
  case StepKeyframe([3]f32), CubicSplineKeyframe([3]f32):
  // Not expected for this test
  }
  switch &kf in clip.channels[0].positions[2] {
  case LinearKeyframe([3]f32):
    kf.value = [3]f32{2, 4, 6}
  case StepKeyframe([3]f32), CubicSplineKeyframe([3]f32):
  // Not expected for this test
  }
  switch &kf in clip.channels[0].rotations[0] {
  case LinearKeyframe(quaternion128):
    kf.value = linalg.quaternion_angle_axis(0, linalg.VECTOR3F32_Z_AXIS)
  case StepKeyframe(quaternion128),
       CubicSplineKeyframe(quaternion128):
  // Not expected for this test
  }
  switch &kf in clip.channels[0].rotations[1] {
  case LinearKeyframe(quaternion128):
    kf.value = linalg.quaternion_angle_axis(
      math.PI / 2,
      linalg.VECTOR3F32_Z_AXIS,
    )
  case StepKeyframe(quaternion128),
       CubicSplineKeyframe(quaternion128):
  // Not expected for this test
  }
  p, r, s := channel_sample_all(clip.channels[0], 1.0)
  testing.expect_value(t, p, [3]f32{1, 2, 3})
  testing.expect(
    t,
    almost_equal_quaternion(
      r,
      linalg.quaternion_angle_axis(math.PI / 4, linalg.VECTOR3F32_Z_AXIS),
    ),
  )
  testing.expect_value(t, s, [3]f32{1, 1, 1})
}

@(test)
animation_sample_benchmark :: proc(t: ^testing.T) {
  n := 1e6
  FRAME_COUNT :: 1e6
  DURATION :: 10.0
  Transform :: struct {
    position: [4]f32,
    rotation: quaternion128,
    scale:    [4]f32,
  }
  Animation :: struct {
    position: []Keyframe([4]f32),
    rotation: []Keyframe(quaternion128),
    scale:    []Keyframe([4]f32),
  }
  options := &time.Benchmark_Options {
    rounds = n,
    bytes = size_of(Transform) * FRAME_COUNT * n,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      anim := new(Animation, allocator)
      time_step := DURATION / f32(FRAME_COUNT)
      value_step := 5000.0 / f32(FRAME_COUNT)
      anim.position = make(
        []Keyframe([4]f32),
        FRAME_COUNT,
        allocator,
      )
      anim.rotation = make(
        []Keyframe(quaternion128),
        FRAME_COUNT,
        allocator,
      )
      anim.scale = make([]Keyframe([4]f32), FRAME_COUNT, allocator)
      for i in 0 ..< FRAME_COUNT {
        anim.position[i] = LinearKeyframe([4]f32) {
          time  = f32(i) * time_step,
          value = [4]f32{f32(i), f32(i), f32(i), f32(i)} * value_step,
        }
        anim.rotation[i] = LinearKeyframe(quaternion128) {
          time  = f32(i) * time_step,
          value = quaternion(
            x = f32(i) * value_step,
            y = f32(i) * value_step,
            z = f32(i) * value_step,
            w = f32(i) * value_step,
          ),
        }
        anim.scale[i] = LinearKeyframe([4]f32) {
          time  = f32(i) * time_step,
          value = [4]f32{f32(i), f32(i), f32(i), f32(i)} * value_step,
        }
      }
      options.input = slice.bytes_from_ptr(anim, size_of(^Animation))
      return nil
    },
    bench = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      anim := cast(^Animation)(raw_data(options.input))
      for i in 0 ..< options.rounds {
        sample_time := DURATION * f32(i % 100) / 100.0
        keyframe_sample(
          anim.position,
          sample_time,
          [4]f32{0, 0, 0, 0},
        )
        keyframe_sample(
          anim.rotation,
          sample_time,
          linalg.QUATERNIONF32_IDENTITY,
        )
        keyframe_sample(anim.scale, sample_time, [4]f32{1, 1, 1, 1})
        options.processed += size_of(Transform)
        options.count += 1
      }
      return nil
    },
    teardown = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      anim := cast(^Animation)(raw_data(options.input))
      delete(anim.position)
      delete(anim.rotation)
      delete(anim.scale)
      free(anim)
      return nil
    },
  }
  err := time.benchmark(options)
  log.infof(
    "Benchmark: %d frames, %d samples in %v (%0.2f MB/s)",
    FRAME_COUNT,
    options.rounds,
    options.duration,
    options.megabytes_per_second,
  )
}

@(test)
test_node_animation_channel_sampling :: proc(t: ^testing.T) {
  // Create a simple animation channel with position, rotation, and scale
  channel := Channel {
    positions = []Keyframe([3]f32) {
      LinearKeyframe([3]f32){time = 0.0, value = {0, 0, 0}},
      LinearKeyframe([3]f32){time = 1.0, value = {10, 0, 0}},
    },
    rotations = []Keyframe(quaternion128) {
      LinearKeyframe(quaternion128) {
        time = 0.0,
        value = linalg.QUATERNIONF32_IDENTITY,
      },
      LinearKeyframe(quaternion128) {
        time = 1.0,
        value = linalg.quaternion_angle_axis(
          math.PI / 2,
          linalg.VECTOR3F32_Z_AXIS,
        ),
      },
    },
    scales    = []Keyframe([3]f32) {
      LinearKeyframe([3]f32){time = 0.0, value = {1, 1, 1}},
      LinearKeyframe([3]f32){time = 1.0, value = {2, 2, 2}},
    },
  }

  // Test at t=0
  pos, rot, scale := channel_sample_all(channel, 0.0)
  testing.expect_value(t, pos, [3]f32{0, 0, 0})
  testing.expect_value(t, scale, [3]f32{1, 1, 1})

  // Test at t=0.5 (midpoint)
  pos, rot, scale = channel_sample_all(channel, 0.5)
  testing.expect_value(t, pos, [3]f32{5, 0, 0})
  testing.expect_value(t, scale, [3]f32{1.5, 1.5, 1.5})

  // Test at t=1.0
  pos, rot, scale = channel_sample_all(channel, 1.0)
  testing.expect_value(t, pos, [3]f32{10, 0, 0})
  testing.expect_value(t, scale, [3]f32{2, 2, 2})
}

@(test)
test_node_animation_step_interpolation :: proc(t: ^testing.T) {
  // Create channel with STEP interpolation (useful for sprite animations or discrete values)
  channel := Channel {
    positions = []Keyframe([3]f32) {
      StepKeyframe([3]f32){time = 0.0, value = {0, 0, 0}},
      StepKeyframe([3]f32){time = 1.0, value = {10, 0, 0}},
      StepKeyframe([3]f32){time = 2.0, value = {20, 0, 0}},
    },
  }

  // With STEP, values should not interpolate
  pos, _, _ := channel_sample_all(channel, 0.0)
  testing.expect_value(t, pos, [3]f32{0, 0, 0})

  pos, _, _ = channel_sample_all(channel, 0.99)
  testing.expect_value(t, pos, [3]f32{0, 0, 0}) // Still first keyframe

  pos, _, _ = channel_sample_all(channel, 1.0)
  testing.expect_value(t, pos, [3]f32{10, 0, 0}) // Jump to second keyframe

  pos, _, _ = channel_sample_all(channel, 1.5)
  testing.expect_value(t, pos, [3]f32{10, 0, 0}) // Hold second value
}
