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
test_channel_sample_some_populates_when_present :: proc(t: ^testing.T) {
	ch: Channel
	channel_init(&ch, position_count = 2, duration = 1.0)
	defer channel_destroy(&ch)
	// override values
	ch.positions[0] = LinearKeyframe([3]f32){time = 0, value = {0, 0, 0}}
	ch.positions[1] = LinearKeyframe([3]f32){time = 1, value = {10, 0, 0}}
	pos, _, _ := channel_sample_some(ch, 0.5)
	v, has := pos.?
	testing.expect(t, has, "should have position")
	testing.expectf(t, math.abs(v.x - 5.0) < 1e-4, "midpoint x=5, got %f", v.x)
}

@(test)
test_layer_update_loop_wraps_time :: proc(t: ^testing.T) {
	l: Layer
	layer_init_fk(&l, 0, duration = 1.0, mode = .LOOP)
	layer_update(&l, 0.7)
	layer_update(&l, 0.5) // total elapsed 1.2 → wrapped to 0.2
	fk := l.data.(FKLayer)
	testing.expectf(t, math.abs(fk.time - 0.2) < 1e-4, "loop wrap, got %f", fk.time)
	testing.expect(t, fk.status == .PLAYING, "still playing")
}

@(test)
test_layer_update_once_stops :: proc(t: ^testing.T) {
	l: Layer
	layer_init_fk(&l, 0, duration = 1.0, mode = .ONCE)
	layer_update(&l, 1.5)
	fk := l.data.(FKLayer)
	testing.expect(t, fk.status == .STOPPED, "ONCE past duration → STOPPED")
	testing.expect(t, fk.time == 1.0, "time clamped to duration")

	// further updates do nothing
	layer_update(&l, 1.0)
	fk = l.data.(FKLayer)
	testing.expect(t, fk.status == .STOPPED && fk.time == 1.0, "stopped layer unchanged")
}

@(test)
test_layer_update_paused_no_progress :: proc(t: ^testing.T) {
	l: Layer
	layer_init_fk(&l, 0, duration = 1.0)
	fk := &l.data.(FKLayer)
	fk.status = .PAUSED
	layer_update(&l, 0.5)
	testing.expect(t, fk.time == 0, "paused layer time stays")
}

@(test)
test_layer_update_ping_pong_reverses :: proc(t: ^testing.T) {
	l: Layer
	layer_init_fk(&l, 0, duration = 1.0, mode = .PING_PONG)
	fk := &l.data.(FKLayer)
	layer_update(&l, 1.5) // overshoot, speed should flip
	testing.expect(t, fk.speed < 0, "speed reversed past duration")
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
