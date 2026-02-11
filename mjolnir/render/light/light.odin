package light

import d "../data"

LightType :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

LightData :: struct {
  color:        [4]f32, // RGB + intensity
  radius:       f32, // range for point/spot lights
  angle_inner:  f32, // inner cone angle for spot lights
  angle_outer:  f32, // outer cone angle for spot lights
  type:         LightType, // LightType
  node_index:   u32, // index into world matrices buffer
  camera_index: u32, // index into camera matrices buffer
  cast_shadow:  b32, // 0 = no shadow, 1 = cast shadow
  _padding:     u32, // Maintain 16-byte alignment
}

Light :: struct {
  using data:    LightData,
  node_handle:   d.NodeHandle,
  camera_handle: d.CameraHandle,
}
