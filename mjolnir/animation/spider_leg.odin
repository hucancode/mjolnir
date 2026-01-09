package animation

import "core:math"
import "core:math/linalg"

SpiderLeg :: struct {
	feet_target:           [3]f32,
	feet_lift_height:      f32,
	feet_lift_frequency:   f32,
	feet_lift_time_offset: f32,
	feet_lift_duration:    f32,
	feet_position:         [3]f32,
	feet_last_target:      [3]f32, // internal
	accumulated_time:      f32,    // internal
}

spider_leg_init :: proc(
	self: ^SpiderLeg,
	initial_target: [3]f32,
	lift_height: f32 = 0.5,
	lift_frequency: f32 = 2.0,
	lift_duration: f32 = 0.4,
	time_offset: f32 = 0.0,
) {
	self.feet_target = initial_target
	self.feet_lift_height = lift_height
	self.feet_lift_frequency = lift_frequency
	self.feet_lift_time_offset = time_offset
	self.feet_lift_duration = lift_duration
	self.feet_position = initial_target
	self.feet_last_target = initial_target
	self.accumulated_time = 0.0
}

spider_leg_update :: proc(self: ^SpiderLeg, delta_time: f32) {
	if self.feet_lift_duration <= 0 {
		self.feet_position = self.feet_target
		self.feet_last_target = self.feet_target
		return
	}

	prev_time := self.accumulated_time
	self.accumulated_time += delta_time

	phase_time := math.mod_f32(
		self.accumulated_time + self.feet_lift_time_offset,
		self.feet_lift_frequency,
	)
	prev_phase_time := math.mod_f32(
		prev_time + self.feet_lift_time_offset,
		self.feet_lift_frequency,
	)

	is_lifting := phase_time < self.feet_lift_duration
	was_lifting := prev_phase_time < self.feet_lift_duration

	if is_lifting {
		t := phase_time / self.feet_lift_duration
		horizontal := linalg.lerp(self.feet_last_target, self.feet_target, t)
		vertical_offset := compute_parabolic_height(t, self.feet_lift_height)
		self.feet_position = horizontal + [3]f32{0, vertical_offset, 0}
	} else {
		self.feet_position = self.feet_last_target
	}

	if was_lifting && !is_lifting {
		self.feet_position = self.feet_target
		self.feet_last_target = self.feet_target
	}
}

// h(t) = 4ht(1-t): parabola with h(0)=0, h(0.5)=h, h(1)=0
compute_parabolic_height :: proc "contextless" (t: f32, max_height: f32) -> f32 {
	return 4.0 * max_height * t * (1.0 - t)
}
