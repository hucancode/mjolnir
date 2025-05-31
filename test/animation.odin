package tests

import "../mjolnir/animation"
import linalg "core:math/linalg"
import "core:testing"

@(test)
test_sample_valid :: proc(t: ^testing.T) {
    frames := []animation.Keyframe(f32){
        {time=0.0, value=0.0},
        {time=1.0, value=10.0},
    };
    result := animation.keyframe_sample(frames, 0.5);
    testing.expect_value(t, result, 5.0);
}

@(test)
test_sample_no_data :: proc(t: ^testing.T) {
    frames := []animation.Keyframe(f32){};
    result := animation.keyframe_sample(frames, 0.5);
    testing.expect_value(t, result, 0.0);
    result = animation.keyframe_sample_or(frames, 0.5, 999.0);
    testing.expect_value(t, result, 999.0);
}

@(test)
test_sample_one_data_point :: proc(t: ^testing.T) {
    frames := []animation.Keyframe(f32){
        {time=0.0, value=42.0},
    };
    result := animation.keyframe_sample(frames, 0.0);
    testing.expect_value(t, result, 42.0);
    result = animation.keyframe_sample(frames, 1.0);
    testing.expect_value(t, result, 42.0);
    result = animation.keyframe_sample(frames, -1.0);
    testing.expect_value(t, result, 42.0);
}

@(test)
test_sample_edge :: proc(t: ^testing.T) {
    frames := []animation.Keyframe(f32){
        {time=0.0, value=1.0},
        {time=1.0, value=3.0},
    };
    result := animation.keyframe_sample(frames, 0.0);
    testing.expect_value(t, result, 1.0);
    result = animation.keyframe_sample(frames, 1.0);
    testing.expect_value(t, result, 3.0);
}

@(test)
test_sample_out_of_range :: proc(t: ^testing.T) {
    frames := []animation.Keyframe(f32){
        {time=0.0, value=2.0},
        {time=1.0, value=4.0},
    };
    // Before first keyframe
    result1 := animation.keyframe_sample(frames, -1.0);
    testing.expect_value(t, result1, 2.0);
    // After last keyframe
    result2 := animation.keyframe_sample(frames, 2.0);
    testing.expect_value(t, result2, 4.0);
}
