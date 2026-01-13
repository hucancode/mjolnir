package animation

import "core:math"
import "core:math/linalg"

TailModifier :: struct {
	frequency:         f32,
	amplitude:         f32,
	propagation_speed: f32,
	damping:           f32,
}

PathModifier :: struct {
	spline: Spline([3]f32),
	offset: f32,
	length: f32,  // Length of the path segment to fit the skeleton to
	speed:  f32,
	loop:   bool,
}

SpiderLegModifier :: struct {
	legs:          []SpiderLeg,
	chain_starts:  []u32,
	chain_lengths: []u32,
}

Modifier :: union {
	TailModifier,
	PathModifier,
	SpiderLegModifier,
}

ProceduralState :: struct {
	bone_indices:     []u32,
	accumulated_time: f32,
	modifier:         Modifier,
}

ProceduralLayer :: struct {
	state: ProceduralState,
}

tail_modifier_update :: proc(
	state: ^ProceduralState,
	params: TailModifier,
	delta_time: f32,
	world_transforms: []BoneTransform,
	layer_weight: f32,
) {
	chain_length := len(state.bone_indices)
	if chain_length < 2 do return

	for i in 1 ..< chain_length {
		bone_idx := state.bone_indices[i]

		phase := state.accumulated_time * params.frequency * 2 * math.PI
		phase += f32(i) * params.propagation_speed

		damped_amplitude := params.amplitude * math.pow(params.damping, f32(i))

		angle_offset := damped_amplitude * math.sin(phase)

		parent_idx := state.bone_indices[i - 1]
		bone_direction := linalg.normalize(
			world_transforms[bone_idx].world_position -
			world_transforms[parent_idx].world_position,
		)

		world_up := [3]f32{0, 1, 0}
		rotation_axis := linalg.normalize(linalg.cross(bone_direction, world_up))
		if linalg.length(rotation_axis) < 0.001 {
			rotation_axis = [3]f32{1, 0, 0}
		}

		delta_rotation := linalg.quaternion_angle_axis(angle_offset, rotation_axis)
		fk_rotation := world_transforms[bone_idx].world_rotation
		procedural_rotation := delta_rotation * fk_rotation

		world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
			fk_rotation,
			procedural_rotation,
			layer_weight,
		)

		scale := extract_scale(world_transforms[bone_idx].world_matrix)
		world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
			world_transforms[bone_idx].world_position,
			world_transforms[bone_idx].world_rotation,
			scale,
		)
	}
}

path_modifier_update :: proc(
	state: ^ProceduralState,
	params: ^PathModifier,
	delta_time: f32,
	world_transforms: []BoneTransform,
	layer_weight: f32,
	bone_lengths: []f32,
) {
	chain_length := len(state.bone_indices)
	if chain_length < 2 || len(params.spline.points) < 2 do return

	// Build arc table BEFORE updating offset!
	if _, has_table := params.spline.arc_table.?; !has_table {
		spline_build_arc_table(&params.spline)
	}

	if bone_lengths == nil do return

	// Now update offset after arc table exists
	if params.speed != 0 {
		params.offset += params.speed * delta_time
		spline_length := spline_arc_length(params.spline)
		if params.loop {
			params.offset = math.mod_f32(params.offset, spline_length)
		} else {
			params.offset = clamp(params.offset, 0.0, spline_length)
		}
	}

	total_chain_length: f32 = 0
	for i in 1 ..< chain_length {
		total_chain_length += bone_lengths[state.bone_indices[i]]
	}

	if total_chain_length <= 0 do return

	spline_length := spline_arc_length(params.spline)

	// Determine the segment length to use
	segment_length := params.length if params.length > 0 else spline_length - params.offset
	cumulative_length: f32 = 0

	// First pass: position all bones along the path segment [offset, offset + segment_length]
	for i in 0 ..< chain_length {
		bone_idx := state.bone_indices[i]

		// Map bone position to segment: offset + (bone_progress * segment_length)
		t := cumulative_length / total_chain_length if total_chain_length > 0 else 0
		s := params.offset + (t * segment_length)

		// Clamp to spline bounds
		if params.loop {
			s = math.mod_f32(s, spline_length)
		} else {
			s = clamp(s, 0, spline_length)
		}

		path_pos := spline_sample_uniform(params.spline, s)

		fk_pos := world_transforms[bone_idx].world_position
		world_transforms[bone_idx].world_position = linalg.lerp(
			fk_pos,
			path_pos,
			layer_weight,
		)

		if i < chain_length - 1 {
			cumulative_length += bone_lengths[state.bone_indices[i + 1]]
		}
	}

	// Second pass: orient each parent bone toward its child
	for i in 0 ..< chain_length - 1 {
		bone_idx := state.bone_indices[i]
		child_idx := state.bone_indices[i + 1]

		// Compute direction from parent to child
		bone_direction := linalg.normalize(
			world_transforms[child_idx].world_position -
			world_transforms[bone_idx].world_position,
		)

		// Bones typically extend along Y-axis (up) in bind pose
		bone_up := linalg.normalize(world_transforms[bone_idx].world_matrix[1].xyz)
		target_rotation := linalg.quaternion_between_two_vector3(bone_up, bone_direction)
		procedural_rotation := target_rotation * world_transforms[bone_idx].world_rotation
		world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
			world_transforms[bone_idx].world_rotation,
			procedural_rotation,
			layer_weight,
		)

		scale := extract_scale(world_transforms[bone_idx].world_matrix)
		world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
			world_transforms[bone_idx].world_position,
			world_transforms[bone_idx].world_rotation,
			scale,
		)
	}

	// Handle last bone (no child to point to, use spline tangent)
	if chain_length > 0 {
		last_idx := chain_length - 1
		bone_idx := state.bone_indices[last_idx]

		cumulative_length = 0
		for i in 1 ..< chain_length {
			cumulative_length += bone_lengths[state.bone_indices[i]]
		}

		s := params.offset + (cumulative_length / total_chain_length) * (spline_length - params.offset)
		epsilon := f32(0.01)
		s_tangent := clamp(s + epsilon, 0, spline_length)
		tangent_pos := spline_sample_uniform(params.spline, s_tangent)
		current_pos := world_transforms[bone_idx].world_position
		tangent := linalg.normalize(tangent_pos - current_pos)

		// Bones typically extend along Y-axis (up) in bind pose
		bone_up := linalg.normalize(world_transforms[bone_idx].world_matrix[1].xyz)
		target_rotation := linalg.quaternion_between_two_vector3(bone_up, tangent)
		procedural_rotation := target_rotation * world_transforms[bone_idx].world_rotation
		world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
			world_transforms[bone_idx].world_rotation,
			procedural_rotation,
			layer_weight,
		)

		scale := extract_scale(world_transforms[bone_idx].world_matrix)
		world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
			world_transforms[bone_idx].world_position,
			world_transforms[bone_idx].world_rotation,
			scale,
		)
	}
}

spider_leg_modifier_update :: proc(
	state: ^ProceduralState,
	params: ^SpiderLegModifier,
	delta_time: f32,
	world_transforms: []BoneTransform,
	layer_weight: f32,
	bone_lengths: []f32,
) {
	num_legs := len(params.legs)
	if num_legs == 0 do return

	for leg_idx in 0 ..< num_legs {
		leg := &params.legs[leg_idx]
		chain_start := params.chain_starts[leg_idx]
		chain_len := params.chain_lengths[leg_idx]

		if chain_len < 2 do continue

		spider_leg_update(leg, delta_time)

		leg_bone_indices := state.bone_indices[chain_start:chain_start + chain_len]

		leg_bone_lengths := make([]f32, chain_len - 1, context.temp_allocator)
		for i in 0 ..< int(chain_len - 1) {
			bone_idx := leg_bone_indices[i + 1]
			leg_bone_lengths[i] = bone_lengths[bone_idx]
		}

		fk_transforms := make([]BoneTransform, chain_len, context.temp_allocator)
		for i in 0 ..< int(chain_len) {
			bone_idx := leg_bone_indices[i]
			fk_transforms[i] = world_transforms[bone_idx]
		}

		ik_target := IKTarget {
			bone_indices    = leg_bone_indices,
			bone_lengths    = leg_bone_lengths,
			target_position = leg.feet_position,
			pole_vector     = [3]f32{0, 0, 0},
			max_iterations  = 10,
			tolerance       = 0.01,
			weight          = 1.0,
			enabled         = true,
		}
		fabrik_solve(world_transforms, ik_target)

		for i in 0 ..< int(chain_len) {
			bone_idx := leg_bone_indices[i]

			ik_pos := world_transforms[bone_idx].world_position
			fk_pos := fk_transforms[i].world_position
			world_transforms[bone_idx].world_position = linalg.lerp(
				fk_pos,
				ik_pos,
				layer_weight,
			)

			ik_rot := world_transforms[bone_idx].world_rotation
			fk_rot := fk_transforms[i].world_rotation
			world_transforms[bone_idx].world_rotation = linalg.quaternion_slerp(
				fk_rot,
				ik_rot,
				layer_weight,
			)

			scale := extract_scale(world_transforms[bone_idx].world_matrix)
			world_transforms[bone_idx].world_matrix = linalg.matrix4_from_trs(
				world_transforms[bone_idx].world_position,
				world_transforms[bone_idx].world_rotation,
				scale,
			)
		}
	}
}

extract_scale :: proc(m: matrix[4, 4]f32) -> [3]f32 {
	scale_x := linalg.length(m[0].xyz)
	scale_y := linalg.length(m[1].xyz)
	scale_z := linalg.length(m[2].xyz)
	return [3]f32{scale_x, scale_y, scale_z}
}

extract_forward_from_matrix :: proc(m: matrix[4, 4]f32) -> [3]f32 {
	return linalg.normalize(m[2].xyz)
}
