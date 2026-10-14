#+build !js
package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

// tail_modifier_update -----------------------------------------

// Chain along +Y with identity rotations, temp-allocated
make_chain_pose :: proc(n: int) -> (positions: [][3]f32, rotations: []quaternion128) {
	positions = make([][3]f32, n, context.temp_allocator)
	rotations = make([]quaternion128, n, context.temp_allocator)
	for i in 0 ..< n {
		positions[i] = {0, f32(i), 0}
		rotations[i] = linalg.QUATERNIONF32_IDENTITY
	}
	return
}

@(test)
test_tail_modifier_initializes_state :: proc(t: ^testing.T) {
	N :: 4
	indices := []u32{0, 1, 2, 3}
	bones := make([]TailBone, N)
	defer delete(bones)
	mod := TailModifier{
		propagation_speed = 0.5,
		damping = 1.0,
		stretch = false,
		bones = bones,
	}
	positions, rotations := make_chain_pose(N)
	bone_lengths := []f32{1, 1, 1, 1}

	tail_modifier_update(&mod, indices, positions, rotations, bone_lengths, 1.0, 1.0 / 60.0)

	// First update must initialize each non-root bone to parent_tip_world
	testing.expect(t, mod.bones[1].is_initialized, "bone 1 init")
	testing.expect(t, mod.bones[2].is_initialized, "bone 2 init")
	testing.expect(t, mod.bones[3].is_initialized, "bone 3 init")
}

@(test)
test_tail_modifier_short_chain_no_op :: proc(t: ^testing.T) {
	indices := []u32{0}
	bones := make([]TailBone, 1)
	defer delete(bones)
	mod := TailModifier{bones = bones, propagation_speed = 0.5, damping = 1.0}
	positions, rotations := make_chain_pose(1)
	bone_lengths := []f32{1}
	// Must not crash with single-bone chain
	tail_modifier_update(&mod, indices, positions, rotations, bone_lengths, 1.0, 0.016)
	testing.expect(t, !mod.bones[0].is_initialized, "single-bone chain skipped")
}

@(test)
test_tail_modifier_mismatched_bones_no_op :: proc(t: ^testing.T) {
	indices := []u32{0, 1, 2}
	bones := make([]TailBone, 1) // mismatch
	defer delete(bones)
	mod := TailModifier{bones = bones, propagation_speed = 0.5, damping = 1.0}
	positions, rotations := make_chain_pose(3)
	bone_lengths := []f32{1, 1, 1}
	tail_modifier_update(&mod, indices, positions, rotations, bone_lengths, 1.0, 0.016)
	testing.expect(t, !mod.bones[0].is_initialized, "mismatch skips")
}

@(test)
test_tail_modifier_settles_to_fk :: proc(t: ^testing.T) {
	// With high stiffness + critical damping + many steps, lagged state should
	// converge to FK target (no movement => no lag). Verify positions stay near FK.
	N :: 3
	indices := []u32{0, 1, 2}
	bones := make([]TailBone, N)
	defer delete(bones)
	mod := TailModifier{propagation_speed = 1.0, damping = 1.0, stretch = false, bones = bones}
	bone_lengths := []f32{1, 1, 1}
	for _ in 0 ..< 200 {
		positions, rotations := make_chain_pose(N)
		tail_modifier_update(&mod, indices, positions, rotations, bone_lengths, 1.0, 1.0 / 60.0)
	}
	// After settling, bone 1 lagged position should be within ~1.5 of FK tip (1,1,0) ish
	for i in 1 ..< N {
		dist := linalg.length(mod.bones[i].position_world)
		testing.expectf(t, dist < 10.0 && !math.is_nan(dist),
			"bone %d position diverged: %f", i, dist)
	}
}
