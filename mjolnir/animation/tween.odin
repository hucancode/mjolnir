package animation

import "core:math"

Mode :: enum {
  Linear,
  QuadIn,
  QuadOut,
  QuadInOut,
  CubicIn,
  CubicOut,
  CubicInOut,
  QuintIn,
  QuintOut,
  QuintInOut,
  SineIn,
  SineOut,
  SineInOut,
  CircIn,
  CircOut,
  CircInOut,
  ExpoIn,
  ExpoOut,
  ExpoInOut,
  ElasticIn,
  ElasticOut,
  ElasticInOut,
  BackIn,
  BackOut,
  BackInOut,
  BounceIn,
  BounceOut,
  BounceInOut,
}

// Core easing functions operating on normalized [0,1] input
ease_linear :: proc(x: f32) -> f32 {
  return x
}

ease_quad_in :: proc(x: f32) -> f32 {
  return x * x
}

ease_quad_out :: proc(x: f32) -> f32 {
  return 1 - (1 - x) * (1 - x)
}

ease_quad_in_out :: proc(x: f32) -> f32 {
  return 2 * x * x if x < 0.5 else 1 - math.pow(-2 * x + 2, 2) / 2
}

ease_cubic_in :: proc(x: f32) -> f32 {
  return x * x * x
}

ease_cubic_out :: proc(x: f32) -> f32 {
  return 1 - math.pow(1 - x, 3)
}

ease_cubic_in_out :: proc(x: f32) -> f32 {
  return 4 * x * x * x if x < 0.5 else 1 - math.pow(-2 * x + 2, 3) / 2
}

ease_quint_in :: proc(x: f32) -> f32 {
  return x * x * x * x * x
}

ease_quint_out :: proc(x: f32) -> f32 {
  return 1 - math.pow(1 - x, 5)
}

ease_quint_in_out :: proc(x: f32) -> f32 {
  return 16 * x * x * x * x * x if x < 0.5 else 1 - math.pow(-2 * x + 2, 5) / 2
}

ease_sine_in :: proc(x: f32) -> f32 {
  return 1 - math.cos(x * math.PI / 2)
}

ease_sine_out :: proc(x: f32) -> f32 {
  return math.sin(x * math.PI / 2)
}

ease_sine_in_out :: proc(x: f32) -> f32 {
  return -(math.cos(math.PI * x) - 1) / 2
}

ease_circ_in :: proc(x: f32) -> f32 {
  return 1 - math.sqrt(1 - x * x)
}

ease_circ_out :: proc(x: f32) -> f32 {
  return math.sqrt(1 - math.pow(x - 1, 2))
}

ease_circ_in_out :: proc(x: f32) -> f32 {
  return(
    (1 - math.sqrt(1 - math.pow(2 * x, 2))) / 2 if x < 0.5 else (math.sqrt(1 - math.pow(-2 * x + 2, 2)) + 1) / 2 \
  )
}

ease_expo_in :: proc(x: f32) -> f32 {
  return 0 if x == 0 else math.pow(2, 10 * x - 10)
}

ease_expo_out :: proc(x: f32) -> f32 {
  return 1 if x == 1 else 1 - math.pow(2, -10 * x)
}

ease_expo_in_out :: proc(x: f32) -> f32 {
  if x == 0 do return 0
  if x == 1 do return 1
  return(
    math.pow(2, 20 * x - 10) / 2 if x < 0.5 else (2 - math.pow(2, -20 * x + 10)) / 2 \
  )
}

ease_elastic_in :: proc(x: f32) -> f32 {
  c4 := f32((2 * math.PI) / 3)
  if x == 0 do return 0
  if x == 1 do return 1
  return -math.pow(2, 10 * x - 10) * math.sin_f32((x * 10 - 10.75) * c4)
}

ease_elastic_out :: proc(x: f32) -> f32 {
  c4 := f32((2 * math.PI) / 3)
  if x == 0 do return 0
  if x == 1 do return 1
  return math.pow(2, -10 * x) * math.sin_f32((x * 10 - 0.75) * c4) + 1
}

ease_elastic_in_out :: proc(x: f32) -> f32 {
  c5 := f32((2 * math.PI) / 4.5)
  if x == 0 do return 0
  if x == 1 do return 1
  return(
    -(math.pow(2, 20 * x - 10) * math.sin_f32((20 * x - 11.125) * c5)) / 2 if x < 0.5 else (math.pow(2, -20 * x + 10) * math.sin_f32((20 * x - 11.125) * c5)) / 2 + 1 \
  )
}

ease_back_in :: proc(x: f32) -> f32 {
  c1 := f32(1.70158)
  c3 := c1 + 1
  return c3 * x * x * x - c1 * x * x
}

ease_back_out :: proc(x: f32) -> f32 {
  c1 := f32(1.70158)
  c3 := c1 + 1
  return 1 + c3 * math.pow(x - 1, 3) + c1 * math.pow(x - 1, 2)
}

ease_back_in_out :: proc(x: f32) -> f32 {
  c1 := f32(1.70158)
  c2 := c1 * 1.525
  return(
    (math.pow(2 * x, 2) * ((c2 + 1) * 2 * x - c2)) / 2 if x < 0.5 else (math.pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2 \
  )
}

ease_bounce_out :: proc(x: f32) -> f32 {
  n1 := f32(7.5625)
  d1 := f32(2.75)
  if x < 1 / d1 {
    return n1 * x * x
  } else if x < 2 / d1 {
    x2 := x - 1.5 / d1
    return n1 * x2 * x2 + 0.75
  } else if x < 2.5 / d1 {
    x2 := x - 2.25 / d1
    return n1 * x2 * x2 + 0.9375
  } else {
    x2 := x - 2.625 / d1
    return n1 * x2 * x2 + 0.984375
  }
}

ease_bounce_in :: proc(x: f32) -> f32 {
  return 1 - ease_bounce_out(1 - x)
}

ease_bounce_in_out :: proc(x: f32) -> f32 {
  return(
    (1 - ease_bounce_out(1 - 2 * x)) / 2 if x < 0.5 else (1 + ease_bounce_out(2 * x - 1)) / 2 \
  )
}

// Dispatch function for all easing modes
ease :: proc(x: f32, mode: Mode) -> f32 {
  switch mode {
  case .Linear:
    return ease_linear(x)
  case .QuadIn:
    return ease_quad_in(x)
  case .QuadOut:
    return ease_quad_out(x)
  case .QuadInOut:
    return ease_quad_in_out(x)
  case .CubicIn:
    return ease_cubic_in(x)
  case .CubicOut:
    return ease_cubic_out(x)
  case .CubicInOut:
    return ease_cubic_in_out(x)
  case .QuintIn:
    return ease_quint_in(x)
  case .QuintOut:
    return ease_quint_out(x)
  case .QuintInOut:
    return ease_quint_in_out(x)
  case .SineIn:
    return ease_sine_in(x)
  case .SineOut:
    return ease_sine_out(x)
  case .SineInOut:
    return ease_sine_in_out(x)
  case .CircIn:
    return ease_circ_in(x)
  case .CircOut:
    return ease_circ_out(x)
  case .CircInOut:
    return ease_circ_in_out(x)
  case .ExpoIn:
    return ease_expo_in(x)
  case .ExpoOut:
    return ease_expo_out(x)
  case .ExpoInOut:
    return ease_expo_in_out(x)
  case .ElasticIn:
    return ease_elastic_in(x)
  case .ElasticOut:
    return ease_elastic_out(x)
  case .ElasticInOut:
    return ease_elastic_in_out(x)
  case .BackIn:
    return ease_back_in(x)
  case .BackOut:
    return ease_back_out(x)
  case .BackInOut:
    return ease_back_in_out(x)
  case .BounceIn:
    return ease_bounce_in(x)
  case .BounceOut:
    return ease_bounce_out(x)
  case .BounceInOut:
    return ease_bounce_in_out(x)
  }
  return x
}

sample :: proc(x: f32, a: f32 = 0, b: f32 = 1, mode: Mode = .Linear) -> f32 {
  t := ease(x, mode)
  return a + (b - a) * t
}
