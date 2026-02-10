package data

EmitterData :: struct {
	initial_velocity:  [3]f32,
	size_start:        f32,
	color_start:       [4]f32,
	color_end:         [4]f32,
	aabb_min:          [3]f32,
	emission_rate:     f32,
	aabb_max:          [3]f32,
	particle_lifetime: f32,
	position_spread:   f32,
	velocity_spread:   f32,
	time_accumulator:  f32,
	size_end:          f32,
	weight:            f32,
	weight_spread:     f32,
	texture_index:     u32,
	node_index:        u32,
}

Emitter :: struct {
	using data:     EmitterData,
	enabled:        b32,
	texture_handle: Image2DHandle,
	node_handle:    NodeHandle,
}

emitter_update_gpu_data :: proc(
  emitter: ^Emitter,
  time_accumulator: f32 = 0.0,
) {
  emitter.time_accumulator = time_accumulator
  emitter.texture_index = emitter.texture_handle.index
  emitter.node_index = emitter.node_handle.index
}