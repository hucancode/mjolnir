package tests

import "../mjolnir/animation"
import "core:log"
import linalg "core:math/linalg"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_sample_valid :: proc(t: ^testing.T) {
  frames := []animation.Keyframe(f32) {
    {time = 0.0, value = 0.0},
    {time = 1.0, value = 10.0},
  }
  result := animation.keyframe_sample(frames, 0.5)
  testing.expect_value(t, result, 5.0)
}

@(test)
test_sample_no_data :: proc(t: ^testing.T) {
  frames := []animation.Keyframe(f32){}
  result := animation.keyframe_sample(frames, 0.5)
  testing.expect_value(t, result, 0.0)
  result = animation.keyframe_sample_or(frames, 0.5, 999.0)
  testing.expect_value(t, result, 999.0)
}

@(test)
test_sample_one_data_point :: proc(t: ^testing.T) {
  frames := []animation.Keyframe(f32){{time = 0.0, value = 42.0}}
  result := animation.keyframe_sample(frames, 0.0)
  testing.expect_value(t, result, 42.0)
  result = animation.keyframe_sample(frames, 1.0)
  testing.expect_value(t, result, 42.0)
  result = animation.keyframe_sample(frames, -1.0)
  testing.expect_value(t, result, 42.0)
}

@(test)
test_sample_edge :: proc(t: ^testing.T) {
  frames := []animation.Keyframe(f32) {
    {time = 0.0, value = 1.0},
    {time = 1.0, value = 3.0},
  }
  result := animation.keyframe_sample(frames, 0.0)
  testing.expect_value(t, result, 1.0)
  result = animation.keyframe_sample(frames, 1.0)
  testing.expect_value(t, result, 3.0)
}

@(test)
test_sample_out_of_range :: proc(t: ^testing.T) {
  frames := []animation.Keyframe(f32) {
    {time = 0.0, value = 2.0},
    {time = 1.0, value = 4.0},
  }
  // Before first keyframe
  result1 := animation.keyframe_sample(frames, -1.0)
  testing.expect_value(t, result1, 2.0)
  // After last keyframe
  result2 := animation.keyframe_sample(frames, 2.0)
  testing.expect_value(t, result2, 4.0)
}

@(test)
test_position_sampling :: proc(t: ^testing.T) {
    frames := []animation.Keyframe(linalg.Vector3f32){
        {time=0.0, value={0, 0, 0}},
        {time=1.0, value={1, 2, 3}},
        {time=2.0, value={2, 4, 6}},
    };
    // value range is small, don't need almost_equal, we can use exact comparison
    // exact matches
    testing.expect_value(t, animation.keyframe_sample(frames, 0.0), linalg.Vector3f32{0, 0, 0});
    testing.expect_value(t, animation.keyframe_sample(frames, 1.0), linalg.Vector3f32{1, 2, 3});
    testing.expect_value(t, animation.keyframe_sample(frames, 2.0), linalg.Vector3f32{2, 4, 6});
    // interpolation
    testing.expect_value(t, animation.keyframe_sample(frames, 0.5), linalg.Vector3f32{0.5, 1, 1.5});
    testing.expect_value(t, animation.keyframe_sample(frames, 1.5), linalg.Vector3f32{1.5, 3, 4.5});
    // out of range
    testing.expect_value(t, animation.keyframe_sample(frames, -1.0), linalg.Vector3f32{0, 0, 0});
    testing.expect_value(t, animation.keyframe_sample(frames, 3.0), linalg.Vector3f32{2, 4, 6});
}

almost_equal_quaternion :: proc(a, b: linalg.Quaternionf32) -> bool {
    return a.x - b.x <= linalg.F32_EPSILON &&
        a.y - b.y <= linalg.F32_EPSILON &&
        a.z - b.z <= linalg.F32_EPSILON &&
        a.w - b.w <= linalg.F32_EPSILON
}

@(test)
test_quaternion_sampling :: proc(t: ^testing.T) {
    q1 := linalg.quaternion_angle_axis_f32(0, {0, 0, 1}); // Identity
    q2 := linalg.quaternion_angle_axis_f32(math.PI, {0, 0, 1}); // 180 around Z
    q3 := linalg.quaternion_angle_axis_f32(math.PI, {0, 1, 0}); // 180 around Y
    q4 := linalg.quaternion_angle_axis_f32(math.PI, {1, 0, 0}); // 180 around X

    frames := []animation.Keyframe(linalg.Quaternionf32){
        {time=0.0, value=q1},
        {time=1.0, value=q2},
        {time=2.0, value=q3},
        {time=3.0, value=q4},
    };
    // exact matches
    testing.expect(t, almost_equal_quaternion(animation.keyframe_sample(frames, 0.0), q1));
    testing.expect(t, almost_equal_quaternion(animation.keyframe_sample(frames, 1.0), q2));
    testing.expect(t, almost_equal_quaternion(animation.keyframe_sample(frames, 2.0), q3));
    testing.expect(t, almost_equal_quaternion(animation.keyframe_sample(frames, 3.0), q4));
    // interpolation
    half_rot := animation.keyframe_sample(frames, 0.5);
    expected_half := linalg.quaternion_angle_axis_f32(math.PI/2, {0, 0, 1});
    testing.expect(t, almost_equal_quaternion(half_rot, expected_half));
}

@(test)
animation_sample_benchmark :: proc(t: ^testing.T) {
  n := 1e6
  FRAME_COUNT :: 1e7
  DURATION :: 10.0
  Transform :: struct {
    position: linalg.Vector4f32,
    rotation: linalg.Quaternionf32,
    scale:    linalg.Vector4f32,
  }
  Animation :: struct {
    position: []animation.Keyframe(linalg.Vector4f32),
    rotation: []animation.Keyframe(linalg.Quaternionf32),
    scale:    []animation.Keyframe(linalg.Vector4f32),
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
        []animation.Keyframe(linalg.Vector4f32),
        FRAME_COUNT,
        allocator,
      )
      anim.rotation = make(
        []animation.Keyframe(linalg.Quaternionf32),
        FRAME_COUNT,
        allocator,
      )
      anim.scale = make(
        []animation.Keyframe(linalg.Vector4f32),
        FRAME_COUNT,
        allocator,
      )
      for i in 0 ..< FRAME_COUNT {
        anim.position[i].value =
          linalg.Vector4f32{f32(i), f32(i), f32(i), f32(i)} * value_step
        anim.rotation[i].value = quaternion(
          x = f32(i) * value_step,
          y = f32(i) * value_step,
          z = f32(i) * value_step,
          w = f32(i) * value_step,
        )
        anim.scale[i].value =
          linalg.Vector4f32{f32(i), f32(i), f32(i), f32(i)} * value_step
        anim.position[i].time = f32(i) * time_step
        anim.rotation[i].time = f32(i) * time_step
        anim.scale[i].time = f32(i) * time_step
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
        animation.keyframe_sample(anim.position, sample_time)
        animation.keyframe_sample(anim.rotation, sample_time)
        animation.keyframe_sample(anim.scale, sample_time)
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
