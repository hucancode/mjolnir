package animation

import "core:math/linalg"
import "core:testing"

@(private = "file")
test_leg_config :: proc(
  offset: [3]f32,
  lift_height: f32 = 0.5,
  lift_frequency: f32 = 2.0,
  lift_duration: f32 = 0.4,
  time_offset: f32 = 0.0,
) -> SpiderLegConfig {
  return {
    offset = offset,
    lift_height = lift_height,
    lift_frequency = lift_frequency,
    lift_duration = lift_duration,
    time_offset = time_offset,
  }
}

@(test)
test_spider_leg_grounded :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({1, 0, 0}))
  spider_leg_update(&leg, 0.5)
  testing.expect_value(t, leg.position, [3]f32{1, 0, 0})
}

@(test)
test_spider_leg_lift_at_cycle_start :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({0, 0, 0}))
  leg.target = {1, 0, 0}
  spider_leg_update(&leg, 0.1)
  testing.expect(t, leg.position.y > 0, "Foot should be lifted")
  testing.expect(
    t,
    leg.position.x > 0 && leg.position.x < 1,
    "Foot should be moving horizontally",
  )
}

@(test)
test_spider_leg_parabolic_height :: proc(t: ^testing.T) {
  testing.expect_value(t, compute_parabolic_height(0.0, 1.0), 0.0)
  testing.expect_value(t, compute_parabolic_height(0.5, 1.0), 1.0)
  testing.expect_value(t, compute_parabolic_height(1.0, 1.0), 0.0)
  testing.expect_value(t, compute_parabolic_height(0.25, 1.0), 0.75)
  testing.expect_value(t, compute_parabolic_height(0.75, 1.0), 0.75)
}

@(test)
test_spider_leg_landing :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({0, 0, 0}))
  leg.target = {1, 0, 0}
  spider_leg_update(&leg, 0.2)
  testing.expect(t, leg.position.y > 0, "Foot should be in air")
  spider_leg_update(&leg, 0.3)
  testing.expect_value(t, leg.position, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.last_target, [3]f32{1, 0, 0})
}

@(test)
test_spider_leg_time_offset :: proc(t: ^testing.T) {
  leg1, leg2: SpiderLeg
  spider_leg_init(&leg1, test_leg_config({0, 0, 0}, time_offset = 0.0))
  spider_leg_init(&leg2, test_leg_config({0, 0, 0}, time_offset = 1.0))
  leg1.target = {1, 0, 0}
  leg2.target = {1, 0, 0}
  spider_leg_update(&leg1, 0.1)
  spider_leg_update(&leg2, 0.1)
  testing.expect(t, leg1.position.y > 0, "Leg1 should be lifting")
  testing.expect_value(t, leg2.position.y, 0.0)
}

@(test)
test_spider_leg_retarget_mid_flight :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({0, 0, 0}))
  leg.target = {1, 0, 0}
  spider_leg_update(&leg, 0.2)
  mid_pos := leg.position
  leg.target = {2, 0, 0}
  spider_leg_update(&leg, 0.1)
  testing.expect(
    t,
    leg.position.x > mid_pos.x,
    "Should retarget toward new position",
  )
}

@(test)
test_spider_leg_zero_duration :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({0, 0, 0}, lift_duration = 0.0))
  leg.target = {1, 0, 0}
  spider_leg_update(&leg, 0.1)
  testing.expect_value(t, leg.position, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.position.y, 0.0)
}

@(test)
test_spider_leg_skips_lift_for_nearby_target :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({1, 0, 0}))
  leg.target = {1.05, 0, 0}
  spider_leg_update(&leg, 0.1)
  testing.expect_value(t, leg.position, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.last_target, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.position.y, 0.0)
}

@(test)
test_spider_leg_target_leads_root_motion :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({1, 0, 0}, lift_duration = 0.5))
  spider_leg_update_with_root(&leg, 0.1, {0, 0, 0})
  spider_leg_update_with_root(&leg, 0.1, {2, 0, 0})
  testing.expect_value(t, leg.target, [3]f32{13, 0, 0})
}

@(test)
test_spider_leg_full_cycle :: proc(t: ^testing.T) {
  leg: SpiderLeg
  spider_leg_init(&leg, test_leg_config({0, 0, 0}))
  leg.target = {1, 0, 0}
  spider_leg_update(&leg, 0.2)
  testing.expect(t, leg.position.y > 0, "Should be lifting")
  spider_leg_update(&leg, 0.3)
  testing.expect_value(t, leg.position.y, 0.0)
  testing.expect_value(t, leg.position, [3]f32{1, 0, 0})
  spider_leg_update(&leg, 1.5)
  testing.expect_value(t, leg.position, [3]f32{1, 0, 0})
  leg.target = {2, 0, 0}
  spider_leg_update(&leg, 0.2)
  testing.expect(t, leg.position.y > 0, "Should lift again in next cycle")
}

@(private = "file")
test_pose :: proc(n: int) -> (positions: [][3]f32, rotations: []quaternion128, lengths: []f32) {
  positions = make([][3]f32, n, context.temp_allocator)
  rotations = make([]quaternion128, n, context.temp_allocator)
  lengths = make([]f32, n, context.temp_allocator)
  for i in 0 ..< n {
    positions[i] = {f32(i), 0, 0}
    rotations[i] = linalg.QUATERNIONF32_IDENTITY
    lengths[i] = 1
  }
  return
}

@(test)
test_spider_leg_modifier_single_leg :: proc(t: ^testing.T) {
  legs: [1]SpiderLeg
  spider_leg_init(&legs[0], test_leg_config({0, 0, 0}))
  legs[0].chain_length = 3
  m := SpiderLegModifier{legs = legs[:]}
  bones := []u32{0, 1, 2}
  positions, rotations, lengths := test_pose(10)
  spider_leg_modifier_update(&m, bones, positions, rotations, lengths, 1.0, 0.1)
  positions[0] = {1, 0, 0}
  spider_leg_modifier_update(&m, bones, positions, rotations, lengths, 1.0, 0.1)
  testing.expect(t, m.legs[0].position.y > 0, "Foot should be lifted in first update")
}

@(test)
test_spider_leg_modifier_multiple_legs :: proc(t: ^testing.T) {
  legs: [2]SpiderLeg
  spider_leg_init(&legs[0], test_leg_config({0, 0, 0}, time_offset = 0.0))
  spider_leg_init(&legs[1], test_leg_config({0, 0, 1}, time_offset = 0.5))
  legs[0].chain_length = 3
  legs[1].chain_start = 3
  legs[1].chain_length = 3
  m := SpiderLegModifier{legs = legs[:]}
  bones := []u32{0, 1, 2, 3, 4, 5}
  positions, rotations, lengths := test_pose(10)
  spider_leg_modifier_update(&m, bones, positions, rotations, lengths, 1.0, 0.1)
  positions[0] = {1, 0, 0}
  spider_leg_modifier_update(&m, bones, positions, rotations, lengths, 1.0, 0.1)
  testing.expect(t, m.legs[0].position.y > 0, "Leg 0 should be lifting")
  testing.expect_value(t, m.legs[1].position.y, 0.0)
}

@(test)
test_spider_leg_modifier_invalid_chain :: proc(t: ^testing.T) {
  legs: [1]SpiderLeg
  spider_leg_init(&legs[0], test_leg_config({0, 0, 0}))
  legs[0].chain_length = 1
  m := SpiderLegModifier{legs = legs[:]}
  positions, rotations, lengths := test_pose(10)
  // Must not crash with a single-bone chain
  spider_leg_modifier_update(&m, []u32{0}, positions, rotations, lengths, 1.0, 0.1)
}
