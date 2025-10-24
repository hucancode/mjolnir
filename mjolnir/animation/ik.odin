package animation

import "core:log"
import "core:math"
import "core:math/linalg"

// Two-bone IK target for analytical solver
// Commonly used for arms (shoulder-elbow-wrist) and legs (hip-knee-ankle)
TwoBoneIKTarget :: struct {
	root_bone_idx:   u32, // Shoulder or hip
	middle_bone_idx: u32, // Elbow or knee
	end_bone_idx:    u32, // Wrist or ankle
	target_position: [3]f32, // Where the end bone should reach
	pole_vector:     [3]f32, // Controls the bending direction (knee/elbow pointing)
	weight:          f32, // Blend weight (0-1), 1 = full IK, 0 = pure FK
	enabled:         bool,
}

// Extract position from a 4x4 transform matrix
matrix_get_position :: proc(m: matrix[4, 4]f32) -> [3]f32 {
	return m[3].xyz
}

// Extract rotation (as quaternion) from a 4x4 transform matrix
matrix_get_rotation :: proc(m: matrix[4, 4]f32) -> quaternion128 {
	return linalg.quaternion_from_matrix4(m)
}

// Extract scale from a 4x4 transform matrix
matrix_get_scale :: proc(m: matrix[4, 4]f32) -> [3]f32 {
    return {linalg.length(m[0]), linalg.length(m[1]), linalg.length(m[2])}
}

// Set position in a 4x4 transform matrix
matrix_set_position :: proc(m: ^matrix[4, 4]f32, pos: [3]f32) {
	m[3].xyz = pos
}

// Set rotation in a 4x4 transform matrix, preserving scale
matrix_set_rotation :: proc(m: ^matrix[4, 4]f32, rot: quaternion128) {
	scale := matrix_get_scale(m^)
	m3 := linalg.matrix3_from_quaternion(rot)

	m[0, 0] = m3[0, 0] * scale.x
	m[0, 1] = m3[0, 1] * scale.x
	m[0, 2] = m3[0, 2] * scale.x

	m[1, 0] = m3[1, 0] * scale.y
	m[1, 1] = m3[1, 1] * scale.y
	m[1, 2] = m3[1, 2] * scale.y

	m[2, 0] = m3[2, 0] * scale.z
	m[2, 1] = m3[2, 1] * scale.z
	m[2, 2] = m3[2, 2] * scale.z
}

// Compute a quaternion that rotates 'from' vector to 'to' vector
// Both vectors should be normalized
quaternion_from_to :: proc(from, to: [3]f32) -> quaternion128 {
	// Handle parallel vectors
	dot := linalg.dot(from, to)
	if dot > 0.9999 {
		return linalg.QUATERNIONF32_IDENTITY
	}
	if dot < -0.9999 {
		// Vectors are opposite, rotate 180 degrees around any perpendicular axis
		axis := linalg.cross(from, [3]f32{1, 0, 0})
		if linalg.length(axis) < 0.0001 {
			axis = linalg.cross(from, [3]f32{0, 1, 0})
		}
		axis = linalg.normalize(axis)
		return linalg.quaternion_angle_axis(math.PI, axis)
	}

	// General case: rotation axis is cross product
	axis := linalg.cross(from, to)
	axis = linalg.normalize(axis)
	angle := math.acos(dot)
	return linalg.quaternion_angle_axis(angle, axis)
}

// Internal struct to store bone world transforms during IK solving
BoneTransform :: struct {
	world_position: [3]f32,
	world_rotation: quaternion128,
	world_matrix:   matrix[4, 4]f32,
}

// Two-bone IK solver using analytical solution (law of cosines)
// This solves for a 3-joint chain (shoulder-elbow-wrist or hip-knee-ankle)
//
// Expects world_transforms to contain the FK-computed world transforms for all bones
// Modifies the transforms for root, middle, and end bones to reach the target
//
// Algorithm:
// 1. Extract world positions from transforms
// 2. Compute bone lengths (constant for a given skeleton)
// 3. Clamp target to reachable range
// 4. Use law of cosines to compute middle joint position
// 5. Recompute bone rotations to match new positions
two_bone_ik_solve :: proc(
	world_transforms: []BoneTransform,
	target: TwoBoneIKTarget,
	bone_lengths: [2]f32, // [upper_length, lower_length]
) {
	if !target.enabled || target.weight <= 0.0 {
		return
	}

	root_idx := target.root_bone_idx
	mid_idx := target.middle_bone_idx
	end_idx := target.end_bone_idx

	// Validate indices
	if root_idx >= u32(len(world_transforms)) ||
	   mid_idx >= u32(len(world_transforms)) ||
	   end_idx >= u32(len(world_transforms)) {
		return
	}

	upper_len := bone_lengths[0]
	lower_len := bone_lengths[1]

	if upper_len < 0.0001 || lower_len < 0.0001 {
		return
	}

	root_pos := world_transforms[root_idx].world_position
	target_pos := target.target_position
	max_reach := upper_len + lower_len

	// Vector from root to target
	to_target := target_pos - root_pos
	target_dist := linalg.length(to_target)

	// Clamp to reachable range
	if target_dist < 0.0001 {
		// Target at root, extend straight down default axis
		to_target = [3]f32{0, -1, 0} * max_reach * 0.5
		target_dist = max_reach * 0.5
		target_pos = root_pos + to_target
	}

	if target_dist > max_reach * 0.999 {
		// Clamp to max reach
		target_dist = max_reach * 0.999
		to_target = linalg.normalize(to_target) * target_dist
		target_pos = root_pos + to_target
	}

	min_reach := math.abs(upper_len - lower_len)
	if target_dist < min_reach {
		target_dist = min_reach
		to_target = linalg.normalize(to_target) * target_dist
		target_pos = root_pos + to_target
	}

	// Law of cosines: find angle at middle joint
	// cos(θ) = (a² + b² - c²) / (2ab)
	cos_mid_angle :=
		(upper_len * upper_len + lower_len * lower_len - target_dist * target_dist) /
		(2.0 * upper_len * lower_len)
	cos_mid_angle = clamp(cos_mid_angle, -1.0, 1.0)

	// Law of cosines: find angle from root to middle joint
	cos_root_angle :=
		(upper_len * upper_len + target_dist * target_dist - lower_len * lower_len) /
		(2.0 * upper_len * target_dist)
	cos_root_angle = clamp(cos_root_angle, -1.0, 1.0)
	root_angle := math.acos(cos_root_angle)

	// Compute bending plane using pole vector
	dir_to_target := linalg.normalize(to_target)
	pole_dir := linalg.normalize(target.pole_vector - root_pos)

	// Project pole onto plane perpendicular to target direction
	pole_projected := pole_dir - dir_to_target * linalg.dot(pole_dir, dir_to_target)
	pole_proj_len := linalg.length(pole_projected)

	if pole_proj_len < 0.0001 {
		// Pole aligned with target, use perpendicular
		up := [3]f32{0, 1, 0}
		if math.abs(linalg.dot(dir_to_target, up)) > 0.9 {
			up = [3]f32{1, 0, 0}
		}
		pole_projected = linalg.cross(dir_to_target, up)
		pole_proj_len = linalg.length(pole_projected)
	}

	pole_projected = pole_projected / pole_proj_len

	// Axis perpendicular to both target and pole (rotation axis for bend)
	bend_axis := linalg.cross(dir_to_target, pole_projected)
	bend_axis = linalg.normalize(bend_axis)

	// Compute middle joint position
	dir_to_mid := dir_to_target * upper_len
	rot_to_mid := linalg.quaternion_angle_axis(root_angle, bend_axis)
	dir_to_mid = linalg.quaternion_mul_vector3(rot_to_mid, dir_to_mid)
	mid_pos_new := root_pos + dir_to_mid

	// Now construct new rotations for root and middle bones
	// Root should point toward middle
	dir_root_to_mid := linalg.normalize(dir_to_mid)

	// Middle should point toward end (target)
	dir_mid_to_end := linalg.normalize(target_pos - mid_pos_new)

	// Compute final world rotations based on IK solution
	// Extract scales from FK matrices to preserve them
	root_scale := matrix_get_scale(world_transforms[root_idx].world_matrix)
	mid_scale := matrix_get_scale(world_transforms[mid_idx].world_matrix)
	end_scale := matrix_get_scale(world_transforms[end_idx].world_matrix)

	// Get FK bone directions
	fk_root_to_mid := world_transforms[mid_idx].world_position - world_transforms[root_idx].world_position
	fk_mid_to_end := world_transforms[end_idx].world_position - world_transforms[mid_idx].world_position
	fk_dir_root := linalg.normalize(fk_root_to_mid)
	fk_dir_mid := linalg.normalize(fk_mid_to_end)

	// Save FK rotations before modifying
	root_rotation_fk := world_transforms[root_idx].world_rotation
	mid_rotation_fk := world_transforms[mid_idx].world_rotation

	// Compute local bone vectors in each bone's local space
	// local_vec = inverse(parent_world_rotation) * world_vec
	bone_vec_root_to_mid_local := linalg.quaternion_mul_vector3(
		linalg.quaternion_inverse(root_rotation_fk),
		fk_root_to_mid,
	)
	bone_vec_mid_to_end_local := linalg.quaternion_mul_vector3(
		linalg.quaternion_inverse(mid_rotation_fk),
		fk_mid_to_end,
	)

	// Compute rotations that transform FK direction to IK direction
	delta_root := quaternion_from_to(fk_dir_root, dir_root_to_mid)
	delta_mid := quaternion_from_to(fk_dir_mid, dir_mid_to_end)

	// Apply deltas to world rotations
	root_rotation_new := delta_root * root_rotation_fk
	mid_rotation_new := delta_mid * mid_rotation_fk

	// Update root bone - rotation only, position stays the same
	world_transforms[root_idx].world_rotation = root_rotation_new
	world_transforms[root_idx].world_matrix = linalg.matrix4_from_trs(
		root_pos, // Keep original position
		root_rotation_new,
		root_scale,
	)

	// After rotating root, recompute middle position from hierarchy
	bone_vec_root_to_mid_world := linalg.quaternion_mul_vector3(
		root_rotation_new,
		bone_vec_root_to_mid_local,
	)
	mid_pos_actual := root_pos + bone_vec_root_to_mid_world

	// Update middle bone
	world_transforms[mid_idx].world_position = mid_pos_actual
	world_transforms[mid_idx].world_rotation = mid_rotation_new
	world_transforms[mid_idx].world_matrix = linalg.matrix4_from_trs(
		mid_pos_actual,
		mid_rotation_new,
		mid_scale,
	)

	// After rotating middle, recompute end position from hierarchy
	bone_vec_mid_to_end_world := linalg.quaternion_mul_vector3(
		mid_rotation_new,
		bone_vec_mid_to_end_local,
	)
	end_pos_actual := mid_pos_actual + bone_vec_mid_to_end_world

	// Update end bone
	world_transforms[end_idx].world_position = end_pos_actual
	world_transforms[end_idx].world_matrix = linalg.matrix4_from_trs(
		end_pos_actual,
		world_transforms[end_idx].world_rotation, // Keep rotation
		end_scale,
	)

	// TODO: Handle weight blending (if target.weight < 1.0, blend between FK and IK)
}
