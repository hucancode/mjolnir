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
