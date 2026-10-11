package render

// Effect structs are pushed verbatim right after the base fields of
// PostProcessPushConstant (offset 32); their layout must match each shader's push block.
GrayscaleEffect :: struct {
  weights:  [3]f32, // zero = Rec. 601 luma, filled by render.add_effect
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

BlurEffect :: struct {
  radius:         f32,
  direction:      f32, // 0.0 = horizontal, 1.0 = vertical; set by render.add_effect
  weight_falloff: f32, // 0.0 = box blur, 1.0 = gaussian blur
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
  direction:   f32, // 0.0 = horizontal, 1.0 = vertical; set by render.add_effect
}

OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

FogEffect :: struct {
  color:   [3]f32,
  density: f32,
  start:   f32,
  end:     f32,
}

CrossHatchEffect :: struct {
  hatch_offset_y:   f32,
  lum_threshold_01: f32,
  lum_threshold_02: f32,
  lum_threshold_03: f32,
  lum_threshold_04: f32,
}

DoFEffect :: struct {
  focus_distance:  f32, // Distance to the focus plane
  focus_range:     f32, // Range where objects are in focus
  blur_strength:   f32, // Maximum blur radius
  bokeh_intensity: f32, // Bokeh effect intensity
}

// nil is the copy pass that brings the input to the output unchanged
PostprocessEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
  FogEffect,
  CrossHatchEffect,
  DoFEffect,
}
