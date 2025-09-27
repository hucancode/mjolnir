package resources

LightData :: struct {
	color:        [4]f32, // RGB + intensity
	radius:       f32,    // range for point/spot lights
	angle_inner:  f32,    // inner cone angle for spot lights (cosine)
	angle_outer:  f32,    // outer cone angle for spot lights (cosine)
	type:         u32,    // LightType
	node_index:   u32,    // index into world matrices buffer
	shadow_map:   u32,    // texture index in bindless array
	enabled:      b32,    // 0 = disabled, 1 = enabled
	cast_shadow:  b32,    // 0 = no shadow, 1 = cast shadow
}

Light :: struct {
	data:         LightData,
	node_handle:  Handle,     // Associated scene node for transform updates
	is_dirty:     bool,       // Needs GPU sync
}
