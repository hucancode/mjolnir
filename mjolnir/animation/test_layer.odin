#+build !js
package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
trs_almost_equal :: proc(a, b: TRS) -> bool {
	return almost_equal_vec3(a.position, b.position) && almost_equal_quaternion(a.rotation, b.rotation, 1e-4) && almost_equal_vec3(a.scale, b.scale)
}

@(test)
test_blend_replace_averages_then_overrides :: proc(t: ^testing.T) {
	rest := TRS_IDENTITY
	a := TRS{position = {2, 0, 0}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 1, 1}}
	b := TRS{position = {0, 4, 0}, rotation = linalg.quaternion_from_euler_angle_y_f32(math.PI / 2), scale = {3, 3, 3}}
	// first layer takes over the rest pose regardless of its weight
	acc, w := rest, f32(0)
	blend_sample(&acc, &w, a, rest, 0.3, .REPLACE)
	testing.expect(t, trs_almost_equal(acc, a), "first REPLACE layer = sample")
	// weights summing to 1 average
	acc, w = rest, 0
	blend_sample(&acc, &w, a, rest, 0.5, .REPLACE)
	blend_sample(&acc, &w, b, rest, 0.5, .REPLACE)
	testing.expectf(t, almost_equal_vec3(acc.position, {1, 2, 0}), "50/50 average, got %v", acc.position)
	testing.expect(t, almost_equal_vec3(acc.scale, {2, 2, 2}))
	half := linalg.quaternion_slerp(a.rotation, b.rotation, 0.5)
	testing.expect(t, almost_equal_quaternion(acc.rotation, half, 1e-4), "rotation slerped halfway")
	// a full-weight layer over a full-weight base replaces it
	acc, w = rest, 0
	blend_sample(&acc, &w, a, rest, 1, .REPLACE)
	blend_sample(&acc, &w, b, rest, 1, .REPLACE)
	testing.expect(t, trs_almost_equal(acc, b), "1 over 1 = top layer")
	// a half-weight layer over a full-weight base lerps halfway
	acc, w = rest, 0
	blend_sample(&acc, &w, a, rest, 1, .REPLACE)
	blend_sample(&acc, &w, b, rest, 0.5, .REPLACE)
	testing.expectf(t, almost_equal_vec3(acc.position, {1, 2, 0}), "0.5 over 1 lerps halfway, got %v", acc.position)
	// three equal layers average to thirds
	c := TRS{position = {0, 0, 6}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 1, 1}}
	acc, w = rest, 0
	blend_sample(&acc, &w, a, rest, 1.0 / 3, .REPLACE)
	blend_sample(&acc, &w, b, rest, 1.0 / 3, .REPLACE)
	blend_sample(&acc, &w, c, rest, 1.0 / 3, .REPLACE)
	testing.expectf(t, almost_equal_vec3(acc.position, {2.0 / 3, 4.0 / 3, 2}), "thirds, got %v", acc.position)
}

@(test)
test_blend_add_is_offset_from_rest :: proc(t: ^testing.T) {
	rest := TRS{position = {0, 1, 0}, rotation = linalg.quaternion_from_euler_angle_x_f32(0.3), scale = {2, 2, 2}}
	base := TRS{position = {5, 0, 0}, rotation = linalg.quaternion_from_euler_angle_y_f32(0.5), scale = {1, 1, 1}}
	// adding the rest pose is a no-op at any weight
	acc, w := base, f32(1)
	blend_sample(&acc, &w, rest, rest, 0.7, .ADD)
	testing.expect(t, trs_almost_equal(acc, base), "ADD of rest pose is a no-op")
	testing.expect(t, w == 1, "ADD does not change accumulated weight")
	// offset scaled by weight
	s := rest
	s.position += {0, 2, 0}
	s.scale = {4, 4, 4}
	acc = base
	blend_sample(&acc, &w, s, rest, 0.5, .ADD)
	testing.expectf(t, almost_equal_vec3(acc.position, {5, 1, 0}), "half the +2 offset, got %v", acc.position)
	testing.expectf(t, almost_equal_vec3(acc.scale, {1.5, 1.5, 1.5}), "half of the x2 scale ratio, got %v", acc.scale)
}

@(test)
test_blend_multiply_and_override :: proc(t: ^testing.T) {
	rest := TRS_IDENTITY
	base := TRS{position = {5, 0, 0}, rotation = linalg.quaternion_from_euler_angle_y_f32(0.5), scale = {2, 2, 2}}
	acc, w := base, f32(1)
	blend_sample(&acc, &w, TRS_IDENTITY, rest, 1, .MULTIPLY)
	testing.expect(t, trs_almost_equal(acc, base), "MULTIPLY by identity is a no-op")
	s := TRS{position = {9, 9, 9}, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {3, 3, 3}}
	blend_sample(&acc, &w, s, rest, 0.5, .MULTIPLY)
	testing.expect(t, almost_equal_vec3(acc.position, base.position), "MULTIPLY ignores position")
	testing.expectf(t, almost_equal_vec3(acc.scale, {4, 4, 4}), "scale * (1 + (3-1)*0.5), got %v", acc.scale)
	acc = base
	blend_sample(&acc, &w, s, rest, 0.4, .OVERRIDE)
	testing.expect(t, trs_almost_equal(acc, base), "OVERRIDE w<=0.5 keeps accumulated")
	blend_sample(&acc, &w, s, rest, 0.6, .OVERRIDE)
	testing.expect(t, trs_almost_equal(acc, s), "OVERRIDE w>0.5 = sample")
}

@(test)
test_fk_playback_advance_loop_wraps :: proc(t: ^testing.T) {
	fk := ClipPlayer{mode = .LOOP, speed = 1}
	playback_advance(&fk, 1.0, 0.7)
	playback_advance(&fk, 1.0, 0.5)
	testing.expectf(t, math.abs(fk.time - 0.2) < 1e-4, "loop wrap, got %f", fk.time)
	testing.expect(t, fk.status == .PLAYING, "still playing")
}

@(test)
test_fk_playback_advance_once_stops :: proc(t: ^testing.T) {
	fk := ClipPlayer{mode = .ONCE, speed = 1}
	playback_advance(&fk, 1.0, 1.5)
	testing.expect(t, fk.status == .STOPPED, "ONCE past duration -> STOPPED")
	testing.expect(t, fk.time == 1.0, "time clamped to duration")
	playback_advance(&fk, 1.0, 1.0)
	testing.expect(t, fk.status == .STOPPED && fk.time == 1.0, "stopped layer unchanged")
}

@(test)
test_fk_playback_advance_zero_duration_noop :: proc(t: ^testing.T) {
	fk := ClipPlayer{mode = .LOOP, speed = 1}
	playback_advance(&fk, 0, 0.5)
	testing.expect(t, fk.time == 0, "zero-duration clip does not advance")
}

@(test)
test_transition_cross_fades :: proc(t: ^testing.T) {
	layers := []Layer{{weight = 1}, {weight = 0}}
	tr := Transition{from_layer = 0, to_layer = 1, duration = 1, curve = .Linear, state = .ACTIVE}
	transition_update(&tr, layers, 0.25)
	testing.expect(t, tr.state == .ACTIVE)
	testing.expectf(t, math.abs(layers[0].weight - 0.75) < 1e-5 && math.abs(layers[1].weight - 0.25) < 1e-5,
		"weights at 25%%: %f %f", layers[0].weight, layers[1].weight)
	transition_update(&tr, layers, 0.5)
	testing.expect(t, math.abs(layers[1].weight - 0.75) < 1e-5, "75%")
	transition_update(&tr, layers, 0.5)
	testing.expect(t, tr.state == .COMPLETE, "complete")
	testing.expect(t, layers[0].weight == 0 && layers[1].weight == 1, "final weights 0/1")
	testing.expect(t, tr.elapsed == tr.duration, "elapsed clamped")
	// further updates are no-ops
	layers[0].weight = 0.5
	transition_update(&tr, layers, 0.5)
	testing.expect(t, layers[0].weight == 0.5, "complete transition does nothing")
}

@(test)
test_transition_zero_duration_completes :: proc(t: ^testing.T) {
	layers := []Layer{{weight = 1}, {weight = 0}}
	tr := Transition{from_layer = 0, to_layer = 1, duration = 0, state = .ACTIVE}
	transition_update(&tr, layers, 0)
	testing.expect(t, tr.state == .COMPLETE)
	testing.expect(t, layers[0].weight == 0 && layers[1].weight == 1)
}

@(test)
test_transition_invalid_layer_resets :: proc(t: ^testing.T) {
	layers := []Layer{{weight = 1}}
	tr := Transition{from_layer = 0, to_layer = 3, duration = 1, state = .ACTIVE}
	transition_update(&tr, layers, 0.1)
	testing.expect(t, tr.state == .NONE)
	testing.expect(t, layers[0].weight == 1)
}

@(test)
test_ik_constraints_uniform :: proc(t: ^testing.T) {
	cs := ik_constraints_uniform(4, [3]f32{1, 0, 1}, [3]f32{0.5, -1, 0.5})
	defer delete(cs)
	testing.expectf(t, len(cs) == 4, "len=4, got %d", len(cs))
	testing.expect(t, cs[0].max_angle == [3]f32{1, 0, 1}, "root constraint")
	testing.expect(t, cs[1].max_angle == [3]f32{0.5, -1, 0.5}, "rest constraint")
	testing.expect(t, cs[3].max_angle == [3]f32{0.5, -1, 0.5}, "last is rest")

	// zero chain returns empty slice
	cs0 := ik_constraints_uniform(0, [3]f32{1, 1, 1}, [3]f32{0, 0, 0})
	defer delete(cs0)
	testing.expect(t, len(cs0) == 0, "empty chain")
}

@(test)
test_fk_playback_advance_ping_pong_reflects :: proc(t: ^testing.T) {
	fk := ClipPlayer{mode = .PING_PONG, speed = 1}
	playback_advance(&fk, 1.0, 1.25)
	testing.expectf(t, math.abs(fk.time - 0.75) < 1e-5 && fk.speed < 0, "reflected at end, got %f speed %f", fk.time, fk.speed)
	playback_advance(&fk, 1.0, 1.0)
	testing.expectf(t, math.abs(fk.time - 0.25) < 1e-5 && fk.speed > 0, "reflected at start, got %f speed %f", fk.time, fk.speed)
}
