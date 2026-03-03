package animation

import "core:math"
import "core:math/linalg"

SPIDER_LEG_MIN_LIFT_DISTANCE_RATIO :: f32(0.1)

SpiderLeg :: struct {
	feet_offset:            [3]f32,
	feet_target:            [3]f32,  // Current target in world space
	feet_lift_height:       f32,
	feet_lift_frequency:    f32,
	feet_lift_time_offset:  f32,
	feet_lift_duration:     f32,
	feet_position:          [3]f32,  // Current foot position in world space
	feet_last_target:       [3]f32,  // Last grounded position in world space
	last_root_position:     [3]f32,
	accumulated_time:       f32,     // internal
}

SpiderLegConfig :: struct {
	initial_offset:   [3]f32,
	lift_height:      f32,
	lift_frequency:   f32,
	lift_duration:    f32,
	time_offset:      f32,
}

spider_leg_init :: proc(
	self: ^SpiderLeg,
	initial_offset: [3]f32,
	lift_height: f32 = 0.5,
	lift_frequency: f32 = 2.0,
	lift_duration: f32 = 0.4,
	time_offset: f32 = 0.0,
) {
	self.feet_offset = initial_offset
	self.feet_target = initial_offset
	self.feet_lift_height = lift_height
	self.feet_lift_frequency = lift_frequency
	self.feet_lift_time_offset = time_offset
	self.feet_lift_duration = lift_duration
	self.feet_position = initial_offset
	self.feet_last_target = initial_offset
	self.last_root_position = {}
	self.accumulated_time = 0.0
}

spider_leg_update :: proc(self: ^SpiderLeg, delta_time: f32) {
	if self.feet_lift_duration <= 0 {
		self.feet_position = self.feet_target
		self.feet_last_target = self.feet_target
		return
	}

	target_delta := self.feet_target - self.feet_last_target
	min_lift_distance_sq := linalg.length2(self.feet_offset) * SPIDER_LEG_MIN_LIFT_DISTANCE_RATIO * SPIDER_LEG_MIN_LIFT_DISTANCE_RATIO
	if linalg.length2(target_delta) <= min_lift_distance_sq {
		self.accumulated_time += delta_time
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

spider_leg_update_with_root :: proc(self: ^SpiderLeg, delta_time: f32, root_position: [3]f32) {
	root_velocity := [3]f32{}
	if self.accumulated_time > 0.0 && delta_time > 0.0 {
		root_velocity = (root_position - self.last_root_position) / delta_time
	}
	target_lead := root_velocity * self.feet_lift_duration

	// Compute target from root + offset, biased slightly forward based on root motion
	self.feet_target = root_position + self.feet_offset + target_lead

	// Initialize on first call (when accumulated_time is still 0)
	if self.accumulated_time == 0.0 && delta_time > 0.0 {
		self.feet_last_target = self.feet_target
		self.feet_position = self.feet_target
	}

	self.last_root_position = root_position

	// Then run existing update logic
	spider_leg_update(self, delta_time)
}

// h(t) = 4ht(1-t): parabola with h(0)=0, h(0.5)=h, h(1)=0
compute_parabolic_height :: proc "contextless" (t: f32, max_height: f32) -> f32 {
	return 4.0 * max_height * t * (1.0 - t)
}
