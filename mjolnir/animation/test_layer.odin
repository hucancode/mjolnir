package animation

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_blend_position_modes :: proc(t: ^testing.T) {
	acc := [3]f32{1, 1, 1}
	v := [3]f32{2, 4, 6}
	w := f32(0.5)

	got := blend_position(acc, v, w, .REPLACE)
	testing.expect(t, got == [3]f32{2, 3, 4}, "REPLACE = acc + v*w")

	got = blend_position(acc, v, w, .ADD)
	testing.expect(t, got == [3]f32{2, 3, 4}, "ADD = acc + v*w")

	got = blend_position(acc, v, w, .MULTIPLY)
	testing.expect(t, got == acc, "MULTIPLY ignores position")

	got = blend_position(acc, v, 0.6, .OVERRIDE)
	testing.expect(t, got == v, "OVERRIDE w>0.5 = v")

	got = blend_position(acc, v, 0.4, .OVERRIDE)
	testing.expect(t, got == acc, "OVERRIDE w<=0.5 = acc")
}

@(test)
test_blend_rotation_modes :: proc(t: ^testing.T) {
	id := linalg.QUATERNIONF32_IDENTITY
	q := linalg.quaternion_from_euler_angle_y_f32(math.PI / 2)

	r := blend_rotation(id, 0, q, 1.0, .REPLACE)
	testing.expectf(t, r == q, "REPLACE with acc_w=0 should return new")

	r = blend_rotation(id, 1.0, q, 1.0, .REPLACE)
	half_y := linalg.quaternion_slerp(id, q, 0.5)
	dot := r.x * half_y.x + r.y * half_y.y + r.z * half_y.z + r.w * half_y.w
	testing.expectf(t, math.abs(math.abs(dot) - 1.0) < 1e-4,
		"REPLACE midweight = slerp halfway, dot=%f", dot)

	r = blend_rotation(q, 0, id, 1.0, .ADD)
	testing.expect(t, r == linalg.quaternion_mul_quaternion(q, id), "ADD = quat mul")

	r = blend_rotation(q, 0, id, 1.0, .MULTIPLY)
	testing.expect(t, r == linalg.quaternion_mul_quaternion(q, id), "MULTIPLY = quat mul")

	r = blend_rotation(id, 0, q, 0.6, .OVERRIDE)
	testing.expect(t, r == q, "OVERRIDE w>0.5 = new")
}

@(test)
test_blend_scale_modes :: proc(t: ^testing.T) {
	acc := [3]f32{1, 1, 1}
	v := [3]f32{2, 2, 2}

	r := blend_scale(acc, v, 0.5, .REPLACE)
	testing.expect(t, r == [3]f32{2, 2, 2}, "REPLACE = acc + v*w")

	r = blend_scale(acc, v, 0.5, .ADD)
	testing.expect(t, r == [3]f32{2, 2, 2}, "ADD = acc + v*w")

	r = blend_scale(acc, v, 1.0, .MULTIPLY)
	testing.expect(t, r == [3]f32{2, 2, 2}, "MULTIPLY w=1: acc * (1 + (v-1)) = acc * v")

	r = blend_scale(acc, v, 0.0, .MULTIPLY)
	testing.expect(t, r == acc, "MULTIPLY w=0: acc unchanged")

	r = blend_scale(acc, v, 0.6, .OVERRIDE)
	testing.expect(t, r == v, "OVERRIDE w>0.5 = v")
}

@(test)
test_fk_playback_advance_loop_wraps :: proc(t: ^testing.T) {
	fk := FKLayer{mode = .LOOP, status = .PLAYING, speed = 1}
	playback_advance(&fk.time, &fk.speed, &fk.status, fk.mode, 1.0, 0.7)
	playback_advance(&fk.time, &fk.speed, &fk.status, fk.mode, 1.0, 0.5)
	testing.expectf(t, math.abs(fk.time - 0.2) < 1e-4, "loop wrap, got %f", fk.time)
	testing.expect(t, fk.status == .PLAYING, "still playing")
}

@(test)
test_fk_playback_advance_once_stops :: proc(t: ^testing.T) {
	fk := FKLayer{mode = .ONCE, status = .PLAYING, speed = 1}
	playback_advance(&fk.time, &fk.speed, &fk.status, fk.mode, 1.0, 1.5)
	testing.expect(t, fk.status == .STOPPED, "ONCE past duration -> STOPPED")
	testing.expect(t, fk.time == 1.0, "time clamped to duration")
	playback_advance(&fk.time, &fk.speed, &fk.status, fk.mode, 1.0, 1.0)
	testing.expect(t, fk.status == .STOPPED && fk.time == 1.0, "stopped layer unchanged")
}

@(test)
test_fk_playback_advance_zero_duration_noop :: proc(t: ^testing.T) {
	fk := FKLayer{mode = .LOOP, status = .PLAYING, speed = 1}
	playback_advance(&fk.time, &fk.speed, &fk.status, fk.mode, 0, 0.5)
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
