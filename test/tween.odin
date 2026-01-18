package tests

import "../mjolnir/animation"
import "core:math"
import "core:testing"

@(test)
test_tween_linear :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0), 0.0)
  testing.expect_value(t, animation.sample(0.5), 0.5)
  testing.expect_value(t, animation.sample(1.0), 1.0)
  testing.expect_value(t, animation.sample(0.5, 10, 20), 15.0)
}

@(test)
test_tween_quad_in :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .QuadIn)
  testing.expect_value(t, result, 0.25)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .QuadIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .QuadIn), 1.0)
}

@(test)
test_tween_quad_out :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .QuadOut)
  testing.expect_value(t, result, 0.75)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .QuadOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .QuadOut), 1.0)
}

@(test)
test_tween_quad_in_out :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .QuadInOut)
  testing.expect_value(t, result, 0.5)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .QuadInOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .QuadInOut), 1.0)
  testing.expect(
    t,
    animation.sample(0.25, 0, 1, .QuadInOut) < 0.25,
    "Should accelerate in first half",
  )
  testing.expect(
    t,
    animation.sample(0.75, 0, 1, .QuadInOut) > 0.75,
    "Should decelerate in second half",
  )
}

@(test)
test_tween_cubic_in :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .CubicIn)
  testing.expect_value(t, result, 0.125)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .CubicIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .CubicIn), 1.0)
}

@(test)
test_tween_cubic_out :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .CubicOut)
  testing.expect_value(t, result, 0.875)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .CubicOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .CubicOut), 1.0)
}

@(test)
test_tween_cubic_in_out :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .CubicInOut)
  testing.expect_value(t, result, 0.5)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .CubicInOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .CubicInOut), 1.0)
}

@(test)
test_tween_quint_in :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .QuintIn)
  expected := f32(0.5 * 0.5 * 0.5 * 0.5 * 0.5)
  testing.expect_value(t, result, expected)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .QuintIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .QuintIn), 1.0)
}

@(test)
test_tween_quint_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .QuintOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .QuintOut), 1.0)
  testing.expect(
    t,
    animation.sample(0.5, 0, 1, .QuintOut) > 0.9,
    "QuintOut should reach near end quickly",
  )
}

@(test)
test_tween_quint_in_out :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 0, 1, .QuintInOut)
  testing.expect_value(t, result, 0.5)
  testing.expect_value(t, animation.sample(0.0, 0, 1, .QuintInOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .QuintInOut), 1.0)
}

@(test)
test_tween_sine_in :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .SineIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .SineIn), 1.0)
  result := animation.sample(0.5, 0, 1, .SineIn)
  testing.expect(
    t,
    result > 0.25 && result < 0.35,
    "SineIn midpoint should be around 0.29",
  )
}

@(test)
test_tween_sine_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .SineOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .SineOut), 1.0)
  result := animation.sample(0.5, 0, 1, .SineOut)
  testing.expect(
    t,
    result > 0.65 && result < 0.75,
    "SineOut midpoint should be around 0.71",
  )
}

@(test)
test_tween_sine_in_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .SineInOut), 0.0)
  testing.expect_value(t, animation.sample(0.5, 0, 1, .SineInOut), 0.5)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .SineInOut), 1.0)
}

@(test)
test_tween_circ_in :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .CircIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .CircIn), 1.0)
  result := animation.sample(0.5, 0, 1, .CircIn)
  testing.expect(
    t,
    result > 0.1 && result < 0.15,
    "CircIn at 0.5 should be around 0.13",
  )
}

@(test)
test_tween_circ_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .CircOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .CircOut), 1.0)
  result := animation.sample(0.5, 0, 1, .CircOut)
  testing.expect(
    t,
    result > 0.85 && result < 0.9,
    "CircOut at 0.5 should be around 0.87",
  )
}

@(test)
test_tween_circ_in_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .CircInOut), 0.0)
  testing.expect_value(t, animation.sample(0.5, 0, 1, .CircInOut), 0.5)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .CircInOut), 1.0)
}

@(test)
test_tween_expo_in :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .ExpoIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .ExpoIn), 1.0)
  result := animation.sample(0.5, 0, 1, .ExpoIn)
  expected := f32(math.pow(f32(2), f32(10 * 0.5 - 10)))
  testing.expect_value(t, result, expected)
}

@(test)
test_tween_expo_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .ExpoOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .ExpoOut), 1.0)
  result := animation.sample(0.5, 0, 1, .ExpoOut)
  expected := f32(1 - math.pow(f32(2), f32(-10 * 0.5)))
  testing.expect_value(t, result, expected)
}

@(test)
test_tween_expo_in_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .ExpoInOut), 0.0)
  testing.expect_value(t, animation.sample(0.5, 0, 1, .ExpoInOut), 0.5)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .ExpoInOut), 1.0)
}

@(test)
test_tween_elastic_in :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .ElasticIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .ElasticIn), 1.0)
  result := animation.sample(0.5, 0, 1, .ElasticIn)
  testing.expect(
    t,
    result < 0.1,
    "ElasticIn should undershoot before reaching end",
  )
}

@(test)
test_tween_elastic_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .ElasticOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .ElasticOut), 1.0)
  result := animation.sample(0.75, 0, 1, .ElasticOut)
  testing.expect(t, result > 0.9, "ElasticOut should overshoot near end")
}

@(test)
test_tween_elastic_in_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .ElasticInOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .ElasticInOut), 1.0)
  testing.expect_value(t, animation.sample(0.5, 0, 1, .ElasticInOut), 0.5)
}

@(test)
test_tween_back_in :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .BackIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .BackIn), 1.0)
  result := animation.sample(0.3, 0, 1, .BackIn)
  testing.expect(t, result < 0, "BackIn should go negative (pull back)")
}

@(test)
test_tween_back_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .BackOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .BackOut), 1.0)
  result := animation.sample(0.7, 0, 1, .BackOut)
  testing.expect(t, result > 1.0, "BackOut should overshoot")
}

@(test)
test_tween_back_in_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .BackInOut), 0.0)
  testing.expect_value(t, animation.sample(0.5, 0, 1, .BackInOut), 0.5)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .BackInOut), 1.0)
}

@(test)
test_tween_bounce_in :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .BounceIn), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .BounceIn), 1.0)
  result := animation.sample(0.5, 0, 1, .BounceIn)
  testing.expect(
    t,
    result >= 0 && result <= 1,
    "BounceIn should stay in range",
  )
}

@(test)
test_tween_bounce_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .BounceOut), 0.0)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .BounceOut), 1.0)
  result := animation.sample(0.5, 0, 1, .BounceOut)
  testing.expect(
    t,
    result >= 0 && result <= 1,
    "BounceOut should stay in range",
  )
}

@(test)
test_tween_bounce_in_out :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.sample(0.0, 0, 1, .BounceInOut), 0.0)
  testing.expect_value(t, animation.sample(0.5, 0, 1, .BounceInOut), 0.5)
  testing.expect_value(t, animation.sample(1.0, 0, 1, .BounceInOut), 1.0)
}

@(test)
test_tween_custom_range :: proc(t: ^testing.T) {
  result := animation.sample(0.5, 10, 20, .Linear)
  testing.expect_value(t, result, 15.0)
  result = animation.sample(0.0, 10, 20, .Linear)
  testing.expect_value(t, result, 10.0)
  result = animation.sample(1.0, 10, 20, .Linear)
  testing.expect_value(t, result, 20.0)
  result = animation.sample(0.5, -5, 5, .Linear)
  testing.expect_value(t, result, 0.0)
}

@(test)
test_tween_symmetry :: proc(t: ^testing.T) {
  modes := []animation.Mode {
    .QuadInOut,
    .CubicInOut,
    .QuintInOut,
    .SineInOut,
    .CircInOut,
    .ExpoInOut,
    .ElasticInOut,
    .BackInOut,
    .BounceInOut,
  }
  for mode in modes {
    result_low := animation.sample(0.25, 0, 1, mode)
    result_high := animation.sample(0.75, 0, 1, mode)
    testing.expect(
      t,
      abs(result_low + result_high - 1.0) < 0.1,
      "InOut modes should be symmetric around midpoint",
    )
  }
}

@(test)
test_tween_endpoint_consistency :: proc(t: ^testing.T) {
  modes := []animation.Mode {
    .Linear,
    .QuadIn,
    .QuadOut,
    .QuadInOut,
    .CubicIn,
    .CubicOut,
    .CubicInOut,
    .QuintIn,
    .QuintOut,
    .QuintInOut,
    .SineIn,
    .SineOut,
    .SineInOut,
    .CircIn,
    .CircOut,
    .CircInOut,
    .ExpoIn,
    .ExpoOut,
    .ExpoInOut,
    .ElasticIn,
    .ElasticOut,
    .ElasticInOut,
    .BackIn,
    .BackOut,
    .BackInOut,
    .BounceIn,
    .BounceOut,
    .BounceInOut,
  }
  for mode in modes {
    start := animation.sample(0.0, 0, 1, mode)
    end := animation.sample(1.0, 0, 1, mode)
    testing.expect_value(t, start, 0.0)
    testing.expect_value(t, end, 1.0)
  }
}
