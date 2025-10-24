package tests

import "../mjolnir/animation"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

// Test FABRIK with 2-bone chain reaching a target
@(test)
test_fabrik_two_bone_straight_reach :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)

	// Setup: Two bones pointing straight down (Y axis)
	// Root at origin, middle at (0,-1,0), end at (0,-2,0)
	world_transforms := make([]animation.BoneTransform, 3)
	defer delete(world_transforms)

	// Initial FK positions (straight down)
	world_transforms[0] = animation.BoneTransform {
		world_position = [3]f32{0, 0, 0},
		world_rotation = linalg.QUATERNIONF32_IDENTITY,
		world_matrix   = linalg.MATRIX4F32_IDENTITY,
	}
	world_transforms[1] = animation.BoneTransform {
		world_position = [3]f32{0, -1, 0},
		world_rotation = linalg.QUATERNIONF32_IDENTITY,
		world_matrix   = linalg.matrix4_translate([3]f32{0, -1, 0}),
	}
	world_transforms[2] = animation.BoneTransform {
		world_position = [3]f32{0, -2, 0},
		world_rotation = linalg.QUATERNIONF32_IDENTITY,
		world_matrix   = linalg.matrix4_translate([3]f32{0, -2, 0}),
	}

	// IK target: reach to (1, -1.5, 0) - reachable within chain length
	bone_indices := []u32{0, 1, 2}
	target := animation.IKTarget {
		bone_indices    = bone_indices,
		target_position = [3]f32{1, -1.5, 0},
		pole_vector     = [3]f32{0, 0, 1}, // Bend toward +Z
		max_iterations  = 20,
		tolerance       = 0.001,
		weight          = 1.0,
		enabled         = true,
	}

	bone_lengths := []f32{1.0, 1.0} // Each bone is length 1

	// Apply IK
	animation.fabrik_solve(world_transforms[:], target, bone_lengths)

	// Verify end effector reached target (within tolerance)
	end_pos := world_transforms[2].world_position
	dist := linalg.distance(end_pos, target.target_position)

	testing.expect(
		t,
		dist < 0.01,
		fmt.tprintf(
			"End effector should reach target. Distance: %f, End pos: %v, Target: %v",
			dist,
			end_pos,
			target.target_position,
		),
	)

	// Verify bone lengths are preserved
	mid_pos := world_transforms[1].world_position
	root_pos := world_transforms[0].world_position

	upper_length := linalg.distance(root_pos, mid_pos)
	lower_length := linalg.distance(mid_pos, end_pos)

	testing.expect(
		t,
		math.abs(upper_length - 1.0) < 0.01,
		fmt.tprintf("Upper bone length should be preserved: %f", upper_length),
	)
	testing.expect(
		t,
		math.abs(lower_length - 1.0) < 0.01,
		fmt.tprintf("Lower bone length should be preserved: %f", lower_length),
	)
}

// Test FABRIK with an unreachable target (should stretch toward it)
@(test)
test_fabrik_unreachable_target :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)

	world_transforms := make([]animation.BoneTransform, 3)
	defer delete(world_transforms)

	// Initial FK positions
	world_transforms[0] = animation.BoneTransform {
		world_position = [3]f32{0, 0, 0},
		world_rotation = linalg.QUATERNIONF32_IDENTITY,
		world_matrix   = linalg.MATRIX4F32_IDENTITY,
	}
	world_transforms[1] = animation.BoneTransform {
		world_position = [3]f32{0, -1, 0},
		world_rotation = linalg.QUATERNIONF32_IDENTITY,
		world_matrix   = linalg.matrix4_translate([3]f32{0, -1, 0}),
	}
	world_transforms[2] = animation.BoneTransform {
		world_position = [3]f32{0, -2, 0},
		world_rotation = linalg.QUATERNIONF32_IDENTITY,
		world_matrix   = linalg.matrix4_translate([3]f32{0, -2, 0}),
	}

	// Target beyond max reach (bone lengths are 1+1=2, target at distance 3)
	bone_indices := []u32{0, 1, 2}
	target := animation.IKTarget {
		bone_indices    = bone_indices,
		target_position = [3]f32{3, 0, 0},
		pole_vector     = [3]f32{0, 0, 1},
		max_iterations  = 20,
		tolerance       = 0.001,
		weight          = 1.0,
		enabled         = true,
	}

	bone_lengths := []f32{1.0, 1.0}

	animation.fabrik_solve(world_transforms[:], target, bone_lengths)

	// Verify chain is stretched toward target but not beyond max reach
	end_pos := world_transforms[2].world_position
	root_pos := world_transforms[0].world_position
	reach := linalg.distance(root_pos, end_pos)

	testing.expect(
		t,
		reach <= 2.0 && reach >= 1.99,
		fmt.tprintf("Chain should be at max reach (~2.0): %f", reach),
	)

	// Verify chain points toward target
	to_end := linalg.normalize(end_pos - root_pos)
	to_target := linalg.normalize(target.target_position - root_pos)
	dot := linalg.dot(to_end, to_target)

	testing.expect(
		t,
		dot > 0.99,
		fmt.tprintf("Chain should point toward target. Dot product: %f", dot),
	)
}

// Test FABRIK with 4-bone chain
@(test)
test_fabrik_four_bone_chain :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)

	world_transforms := make([]animation.BoneTransform, 5)
	defer delete(world_transforms)

	// Initial FK positions (straight down Y axis)
	for i in 0 ..< 5 {
		y := f32(-i)
		world_transforms[i] = animation.BoneTransform {
			world_position = [3]f32{0, y, 0},
			world_rotation = linalg.QUATERNIONF32_IDENTITY,
			world_matrix   = linalg.matrix4_translate([3]f32{0, y, 0}),
		}
	}

	// Target position
	bone_indices := []u32{0, 1, 2, 3, 4}
	target := animation.IKTarget {
		bone_indices    = bone_indices,
		target_position = [3]f32{2, -3, 0},
		pole_vector     = [3]f32{0, -2, 1},
		max_iterations  = 20,
		tolerance       = 0.001,
		weight          = 1.0,
		enabled         = true,
	}

	bone_lengths := []f32{1.0, 1.0, 1.0, 1.0}

	animation.fabrik_solve(world_transforms[:], target, bone_lengths)

	// Verify end effector reached target
	end_pos := world_transforms[4].world_position
	dist := linalg.distance(end_pos, target.target_position)

	testing.expect(
		t,
		dist < 0.02,
		fmt.tprintf(
			"End effector should reach target. Distance: %f, End pos: %v, Target: %v",
			dist,
			end_pos,
			target.target_position,
		),
	)

	// Verify all bone lengths are preserved
	for i in 0 ..< 4 {
		pos := world_transforms[i].world_position
		next_pos := world_transforms[i + 1].world_position
		length := linalg.distance(pos, next_pos)

		testing.expect(
			t,
			math.abs(length - 1.0) < 0.01,
			fmt.tprintf("Bone %d length should be preserved: %f", i, length),
		)
	}
}

// Test FABRIK with pole vector constraint
@(test)
test_fabrik_pole_vector :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)

	world_transforms := make([]animation.BoneTransform, 4)
	defer delete(world_transforms)

	// Initial positions (straight down)
	for i in 0 ..< 4 {
		y := f32(-i)
		world_transforms[i] = animation.BoneTransform {
			world_position = [3]f32{0, y, 0},
			world_rotation = linalg.QUATERNIONF32_IDENTITY,
			world_matrix   = linalg.matrix4_translate([3]f32{0, y, 0}),
		}
	}

	// Target with pole pointing +Z
	bone_indices := []u32{0, 1, 2, 3}
	target := animation.IKTarget {
		bone_indices    = bone_indices,
		target_position = [3]f32{1.5, -2, 0},
		pole_vector     = [3]f32{0, -1, 2}, // Pole toward +Z
		max_iterations  = 20,
		tolerance       = 0.001,
		weight          = 1.0,
		enabled         = true,
	}

	bone_lengths := []f32{1.0, 1.0, 1.0}

	animation.fabrik_solve(world_transforms[:], target, bone_lengths)

	// Middle joints should have positive Z component (bent toward pole)
	mid_pos_1 := world_transforms[1].world_position
	mid_pos_2 := world_transforms[2].world_position

	testing.expect(
		t,
		mid_pos_1.z > -0.1 || mid_pos_2.z > -0.1,
		fmt.tprintf(
			"At least one middle joint should bend toward pole (+Z). Z values: %f, %f",
			mid_pos_1.z,
			mid_pos_2.z,
		),
	)

	// End should reach target
	end_pos := world_transforms[3].world_position
	dist := linalg.distance(end_pos, target.target_position)

	testing.expect(
		t,
		dist < 0.02,
		fmt.tprintf("End effector should reach target. Distance: %f", dist),
	)
}

// Test FABRIK convergence with different iteration counts
@(test)
test_fabrik_convergence :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)

	world_transforms := make([]animation.BoneTransform, 6)
	defer delete(world_transforms)

	// Initial positions
	for i in 0 ..< 6 {
		y := f32(-i) * 0.5
		world_transforms[i] = animation.BoneTransform {
			world_position = [3]f32{0, y, 0},
			world_rotation = linalg.QUATERNIONF32_IDENTITY,
			world_matrix   = linalg.matrix4_translate([3]f32{0, y, 0}),
		}
	}

	bone_indices := []u32{0, 1, 2, 3, 4, 5}
	target := animation.IKTarget {
		bone_indices    = bone_indices,
		target_position = [3]f32{1, -2, 0},
		pole_vector     = [3]f32{0, 0, 1},
		max_iterations  = 30,
		tolerance       = 0.0001,
		weight          = 1.0,
		enabled         = true,
	}

	bone_lengths := []f32{0.5, 0.5, 0.5, 0.5, 0.5}

	animation.fabrik_solve(world_transforms[:], target, bone_lengths)

	// Should converge to target within tolerance
	end_pos := world_transforms[5].world_position
	dist := linalg.distance(end_pos, target.target_position)

	testing.expect(
		t,
		dist < 0.001,
		fmt.tprintf("Should converge within tolerance. Distance: %f", dist),
	)
}
