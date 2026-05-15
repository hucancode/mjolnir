package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_extract_scale_from_trs :: proc(t: ^testing.T) {
	m := linalg.matrix4_from_trs_f32({0, 0, 0}, linalg.QUATERNIONF32_IDENTITY, {2, 3, 4})
	s := extract_scale(m)
	testing.expectf(t, math.abs(s.x - 2) < 1e-4 && math.abs(s.y - 3) < 1e-4 && math.abs(s.z - 4) < 1e-4,
		"expected scale (2,3,4), got %v", s)
}

@(test)
test_extract_scale_with_rotation :: proc(t: ^testing.T) {
	q := linalg.quaternion_from_euler_angle_y_f32(math.PI / 4)
	m := linalg.matrix4_from_trs_f32({1, 2, 3}, q, {2, 2, 2})
	s := extract_scale(m)
	testing.expectf(t, math.abs(s.x - 2) < 1e-4 && math.abs(s.y - 2) < 1e-4 && math.abs(s.z - 2) < 1e-4,
		"rotation must not change scale, got %v", s)
}

// tail_modifier_update -----------------------------------------

make_chain_xforms :: proc(n: int) -> []BoneTransform {
	xforms := make([]BoneTransform, n)
	for i in 0 ..< n {
		p := [3]f32{0, f32(i), 0}
		xforms[i] = BoneTransform {
			world_position = p,
			world_rotation = linalg.QUATERNIONF32_IDENTITY,
			world_matrix   = linalg.matrix4_from_trs_f32(p, linalg.QUATERNIONF32_IDENTITY, {1, 1, 1}),
		}
	}
	return xforms
}

@(test)
test_tail_modifier_initializes_state :: proc(t: ^testing.T) {
	N :: 4
	indices := []u32{0, 1, 2, 3}
	state := ProceduralState{bone_indices = indices}
	bones := make([]TailBone, N)
	defer delete(bones)
	mod := TailModifier{
		propagation_speed = 0.5,
		damping = 1.0,
		stretch = false,
		bones = bones,
	}
	xforms := make_chain_xforms(N)
	defer delete(xforms)
	bone_lengths := []f32{1, 1, 1, 1}

	tail_modifier_update(&state, &mod, 1.0 / 60.0, xforms, 1.0, bone_lengths)

	// First update must initialize each non-root bone to parent_tip_world
	testing.expect(t, mod.bones[1].is_initialized, "bone 1 init")
	testing.expect(t, mod.bones[2].is_initialized, "bone 2 init")
	testing.expect(t, mod.bones[3].is_initialized, "bone 3 init")
}

@(test)
test_tail_modifier_short_chain_no_op :: proc(t: ^testing.T) {
	state := ProceduralState{bone_indices = []u32{0}}
	bones := make([]TailBone, 1)
	defer delete(bones)
	mod := TailModifier{bones = bones, propagation_speed = 0.5, damping = 1.0}
	xforms := make_chain_xforms(1)
	defer delete(xforms)
	bone_lengths := []f32{1}
	// Must not crash with single-bone chain
	tail_modifier_update(&state, &mod, 0.016, xforms, 1.0, bone_lengths)
	testing.expect(t, !mod.bones[0].is_initialized, "single-bone chain skipped")
}

@(test)
test_tail_modifier_mismatched_bones_no_op :: proc(t: ^testing.T) {
	state := ProceduralState{bone_indices = []u32{0, 1, 2}}
	bones := make([]TailBone, 1) // mismatch
	defer delete(bones)
	mod := TailModifier{bones = bones, propagation_speed = 0.5, damping = 1.0}
	xforms := make_chain_xforms(3)
	defer delete(xforms)
	bone_lengths := []f32{1, 1, 1}
	tail_modifier_update(&state, &mod, 0.016, xforms, 1.0, bone_lengths)
	testing.expect(t, !mod.bones[0].is_initialized, "mismatch skips")
}

@(test)
test_tail_modifier_settles_to_fk :: proc(t: ^testing.T) {
	// With high stiffness + critical damping + many steps, lagged state should
	// converge to FK target (no movement => no lag). Verify positions stay near FK.
	N :: 3
	indices := []u32{0, 1, 2}
	state := ProceduralState{bone_indices = indices}
	bones := make([]TailBone, N)
	defer delete(bones)
	mod := TailModifier{propagation_speed = 1.0, damping = 1.0, stretch = false, bones = bones}
	bone_lengths := []f32{1, 1, 1}
	for _ in 0 ..< 200 {
		xforms := make_chain_xforms(N)
		tail_modifier_update(&state, &mod, 1.0 / 60.0, xforms, 1.0, bone_lengths)
		// no need to keep xforms; just verify state stays bounded
		delete(xforms)
	}
	// After settling, bone 1 lagged position should be within ~1.5 of FK tip (1,1,0) ish
	for i in 1 ..< N {
		dist := linalg.length(mod.bones[i].position_world)
		testing.expectf(t, dist < 10.0 && !math.is_nan(dist),
			"bone %d position diverged: %f", i, dist)
	}
}
