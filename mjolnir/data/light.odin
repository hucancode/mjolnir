package data

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
	node_handle:   NodeHandle, // Associated scene node for transform updates
	camera_handle: CameraHandle, // Camera (regular or spherical based on light type)
}

light_init :: proc(
  self: ^Light,
  light_type: LightType,
  node_handle: NodeHandle,
  color: [4]f32,
  radius: f32,
  angle_inner: f32,
  angle_outer: f32,
  cast_shadow: b32,
) {
  self.type = light_type
  self.node_handle = node_handle
  self.cast_shadow = cast_shadow
  self.color = color
  self.radius = radius
  self.angle_inner = angle_inner
  self.angle_outer = angle_outer
  self.node_index = node_handle.index
  self.camera_handle = {}
  self.camera_index = 0xFFFFFFFF
}