package mjolnir

import linalg "core:math/linalg"

PointLight :: struct {
  color:       linalg.Vector4f32,
  radius:      f32,
  cast_shadow: bool,
}
DirectionalLight :: struct {
  color:       linalg.Vector4f32,
  cast_shadow: bool,
}
SpotLight :: struct {
  color:       linalg.Vector4f32,
  radius:      f32,
  angle:       f32,
  cast_shadow: bool,
}

Light :: union {
  PointLight,
  DirectionalLight,
  SpotLight,
}

// Helper functions to create lights
make_point_light :: proc(
  color: linalg.Vector4f32,
  radius: f32,
  cast_shadow: bool,
) -> Light {
  return PointLight{color = color, radius = radius, cast_shadow = cast_shadow}
}

make_directional_light :: proc(
  color: linalg.Vector4f32,
  cast_shadow: bool,
) -> Light {
  return DirectionalLight{color = color, cast_shadow = cast_shadow}
}

make_spot_light :: proc(
  angle: f32,
  color: linalg.Vector4f32,
  radius: f32,
  cast_shadow: bool,
) -> Light {
  return SpotLight {
    color = color,
    radius = radius,
    cast_shadow = cast_shadow,
    angle = angle,
  }
}
